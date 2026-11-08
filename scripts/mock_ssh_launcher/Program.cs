using System.Diagnostics;
using System.Text.RegularExpressions;

// Binary staging is the only request that carries stdin. Handle it directly
// in the external ssh.exe adapter so the offline harness tests the production
// BaseStream writer without introducing a second pair of redirected pipes.
// All command semantics after staging remain in mock_maind_ssh_transport.py.
var command = args.Length == 0 ? "" : args[^1];
if (command.Contains("umask 077; cat >", StringComparison.Ordinal)) {
    var root = Environment.GetEnvironmentVariable("MAIND_MOCK_ROOT")
        ?? throw new InvalidOperationException("MAIND_MOCK_ROOT is required");
    var match = Regex.Match(command, "cat > '([^']+)'$");
    if (!match.Success || !match.Groups[1].Value.StartsWith('/'))
        throw new InvalidOperationException("unsafe or invalid mock staging target");
    var relative = match.Groups[1].Value.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
    var target = Path.GetFullPath(Path.Combine(root, "remote", relative));
    var remoteRoot = Path.GetFullPath(Path.Combine(root, "remote")) + Path.DirectorySeparatorChar;
    if (!target.StartsWith(remoteRoot, StringComparison.OrdinalIgnoreCase))
        throw new InvalidOperationException("mock staging target escaped remote root");
    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
    using var destination = File.Create(target);
    Console.OpenStandardInput().CopyTo(destination);
    return 0;
}

var python = Environment.GetEnvironmentVariable("MAIND_MOCK_PYTHON")
    ?? throw new InvalidOperationException("MAIND_MOCK_PYTHON is required");
var script = Environment.GetEnvironmentVariable("MAIND_MOCK_SSH_SCRIPT")
    ?? throw new InvalidOperationException("MAIND_MOCK_SSH_SCRIPT is required");
var start = new ProcessStartInfo(python) {
    UseShellExecute = false,
    RedirectStandardInput = true,
    RedirectStandardOutput = true,
    RedirectStandardError = true,
};
start.ArgumentList.Add(script);
foreach (var argument in args) start.ArgumentList.Add(argument);
using var process = Process.Start(start) ?? throw new InvalidOperationException("mock ssh failed to start");
// Non-staging mock commands never carry stdin. Closing it immediately also
// makes the adapter deterministic when the harness itself runs detached and
// therefore has an inherited console pipe that never reaches EOF.
process.StandardInput.Close();
var output = process.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput());
var error = process.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError());
await process.WaitForExitAsync();
await Task.WhenAll(output, error);
return process.ExitCode;
