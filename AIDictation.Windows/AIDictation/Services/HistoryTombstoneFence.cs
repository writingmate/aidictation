using System;
using System.Collections.Generic;

namespace AIDictation.Services;

/// <summary>
/// Same-process deletion fence for the History mirror. Recording IDs are
/// stable and never reused, so once durable Store deletion has committed no
/// detached publication may recreate that ID. Store recovery reapplies the
/// fence after a process restart.
/// </summary>
public sealed class HistoryTombstoneFence
{
    private readonly object _lock = new();
    private readonly HashSet<Guid> _recordingIds = new();

    public bool CanPublish(Guid recordingId)
    {
        lock (_lock) return !_recordingIds.Contains(recordingId);
    }

    public void Commit(Guid recordingId)
    {
        lock (_lock) _recordingIds.Add(recordingId);
    }

    public void Commit(IEnumerable<Guid> recordingIds)
    {
        lock (_lock)
        {
            foreach (var recordingId in recordingIds) _recordingIds.Add(recordingId);
        }
    }
}
