using System.Diagnostics;

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
var input = Console.OpenStandardInput().CopyToAsync(process.StandardInput.BaseStream)
    .ContinueWith(_ => process.StandardInput.Close());
var output = process.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput());
var error = process.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError());
process.WaitForExit();
await Task.WhenAll(input, output, error);
return process.ExitCode;
