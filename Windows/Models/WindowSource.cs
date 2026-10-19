namespace DogSC.Windows.Models;

public sealed class WindowSource
{
    public required string Title { get; init; }
    public required IntPtr Handle { get; init; }
    public required uint ProcessId { get; init; }

    public override string ToString() => Title;
}