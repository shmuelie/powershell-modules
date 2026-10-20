using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Shmuelie.Copilot
{
    public sealed class LifecycleJournalRecord
    {
        public string Json { get; set; }
        public bool Incomplete { get; set; }
    }

    public sealed class SessionIdentityJournal : IDisposable
    {
        private readonly IEnumerator<LifecycleJournalRecord> records;

        private SessionIdentityJournal(string path) { records = ReadRecords(path).GetEnumerator(); }
        public static SessionIdentityJournal Read(string path) { return new SessionIdentityJournal(path); }
        public LifecycleJournalRecord Current { get { return records.Current; } }
        public bool MoveNext() { return records.MoveNext(); }
        public void Dispose() { records.Dispose(); }

        private static IEnumerable<LifecycleJournalRecord> ReadRecords(string path)
        {
            long length = new FileInfo(path).Length;
            using var scan = Open(path, length);
            using var replay = Open(path, length);
            var buffer = new char[16384];
            long replayPosition = 0;
            long position = 0;
            while (true)
            {
                long start = position;
                int depth = 0;
                bool quoted = false, escaped = false, expectType = false, foundType = false;
                string pending = null, type = null;
                var token = new StringBuilder(256);
                bool tokenOverflow = false;
                int c;
                while ((c = scan.Read()) != -1)
                {
                    position++;
                    if (c == '\n' || c == '\r')
                        break;
                    if (quoted)
                    {
                        if (!escaped && c == '"')
                        {
                            quoted = false;
                            if (depth == 1)
                                pending = tokenOverflow ? null : token.ToString();
                        }
                        else
                        {
                            if (depth == 1 && !tokenOverflow)
                            {
                                if (token.Length < 256)
                                    token.Append((char)c);
                                else
                                    tokenOverflow = true;
                            }
                            if (escaped)
                                escaped = false;
                            else if (c == '\\')
                                escaped = true;
                        }
                        continue;
                    }
                    if (char.IsWhiteSpace((char)c))
                        continue;
                    if (pending != null)
                    {
                        if (c == ':')
                            expectType = !foundType && Decode(pending) == "type";
                        else if (expectType && !foundType)
                        {
                            type = Decode(pending);
                            foundType = true;
                            expectType = false;
                        }
                        pending = null;
                    }
                    if (c == '"')
                    {
                        quoted = true;
                        escaped = false;
                        token.Clear();
                        tokenOverflow = false;
                    }
                    else if (c == '{' || c == '[')
                    {
                        if (expectType && depth == 1)
                            throw new FormatException("Event type must be a string.");
                        depth++;
                    }
                    else if (c == '}' || c == ']')
                        depth--;
                }
                if (position == start)
                    yield break;
                if (pending != null && expectType && !foundType)
                    type = Decode(pending);
                if (c == -1 && (quoted || depth > 0))
                {
                    yield return new LifecycleJournalRecord { Incomplete = true };
                    yield break;
                }
                bool lifecycle = type == "session.start" || type == "session.resume" ||
                    type == "session.context_changed";
                // Replay only lifecycle records; a conversation line can be arbitrarily large.
                Advance(replay, buffer, start - replayPosition, null);
                StringBuilder json = lifecycle ? new StringBuilder() : null;
                Advance(replay, buffer, position - start, json);
                replayPosition = position;
                if (lifecycle)
                    yield return new LifecycleJournalRecord { Json = json.ToString() };
                if (c == -1)
                    yield break;
            }
        }

        private static StreamReader Open(string path, long length)
        {
            return new StreamReader(new SnapshotStream(path, length), Encoding.UTF8, true, 16384);
        }

        private sealed class SnapshotStream : FileStream
        {
            private readonly long length;

            public SnapshotStream(string path, long length)
                : base(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)
            {
                this.length = length;
            }

            public override int Read(byte[] buffer, int offset, int count)
            {
                return base.Read(buffer, offset, (int)Math.Min(count, Math.Max(0, length - Position)));
            }

            public override int Read(Span<byte> buffer)
            {
                return base.Read(buffer.Slice(0, (int)Math.Min(buffer.Length, Math.Max(0, length - Position))));
            }
        }

        private static void Advance(StreamReader reader, char[] buffer, long count, StringBuilder text)
        {
            while (count > 0)
            {
                int read = reader.Read(buffer, 0, (int)Math.Min(count, buffer.Length));
                if (read == 0)
                    throw new EndOfStreamException("The identity recovery journal changed while being read.");
                text?.Append(buffer, 0, read);
                count -= read;
            }
        }

        private static string Decode(string text)
        {
            if (text.IndexOf('\\') < 0)
                return text;
            var decoded = new StringBuilder(text.Length);
            for (int i = 0; i < text.Length; i++)
            {
                char c = text[i];
                if (c != '\\')
                {
                    decoded.Append(c);
                    continue;
                }
                if (++i == text.Length)
                    throw new FormatException("Invalid JSON string escape.");
                switch (text[i])
                {
                    case '"': decoded.Append('"'); break;
                    case '\\': decoded.Append('\\'); break;
                    case '/': decoded.Append('/'); break;
                    case 'b': decoded.Append('\b'); break;
                    case 'f': decoded.Append('\f'); break;
                    case 'n': decoded.Append('\n'); break;
                    case 'r': decoded.Append('\r'); break;
                    case 't': decoded.Append('\t'); break;
                    case 'u':
                        if (i + 4 >= text.Length ||
                            !ushort.TryParse(text.Substring(i + 1, 4),
                                System.Globalization.NumberStyles.HexNumber,
                                System.Globalization.CultureInfo.InvariantCulture, out ushort value))
                            throw new FormatException("Invalid JSON Unicode escape.");
                        decoded.Append((char)value);
                        i += 4;
                        break;
                    default: throw new FormatException("Invalid JSON string escape.");
                }
            }
            return decoded.ToString();
        }
    }
}
