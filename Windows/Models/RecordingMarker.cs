namespace DogSC.Windows.Models;

public sealed record RecordingMarker(
    int Index,
    double TimeSeconds,
    string Label,
    DateTimeOffset CreatedAt);