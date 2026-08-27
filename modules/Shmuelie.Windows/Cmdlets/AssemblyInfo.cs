using System.Runtime.CompilerServices;

// Grants the Pester test helper (compiled via Add-Type -OutputAssembly) access
// to internals (IHiveOperations, UserProfile, TestHiveOperations) so the helper
// can install a fake seam without requiring a public test API.
[assembly: InternalsVisibleTo("Shmuelie.Windows.Tests.Helpers")]
