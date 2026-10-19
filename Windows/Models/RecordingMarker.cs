namespace DogSC.Windows.Models;

public sealed record RecordingMarker(
    int Index,
    double TimeSeconds,
    string Label,
    DateTimeOffset CreatedAt)
{
    public string DisplayLabel => $"{Label}  —  {TimeSeconds:F2} 秒";
}