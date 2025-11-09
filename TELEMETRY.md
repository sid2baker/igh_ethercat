# Telemetry Events

All events follow `:telemetry` spec. Attach with `:telemetry.attach/4` or `:telemetry.attach_many/4`.

## Event Reference

### Master Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:ethercat, :master, :state]` | none | `:state` - `:offline`, `:stale`, `:synced`, `:operational` |
| `[:ethercat, :master, :connect]` | `:duration` (native) | `:result` - `:success`, `:link_down`, `:error`<br>`:error` - description (if error) |
| `[:ethercat, :master, :sync_slaves]` | `:duration` (native)<br>`:count` (on success) | `:result` - `:success` or `:error`<br>`:error` - description (if error) |
| `[:ethercat, :master, :activate]` | `:duration` (native) | `:domains` - count<br>`:slaves` - count<br>`:result`, `:error` (if error) |

### Child Process Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:ethercat, :domain, :terminate]` | `:subscriber_count` | `:reason` |
| `[:ethercat, :slave, :terminate]` | `:position` | `:reason`, `:driver` |

## Quick Attach

```elixir
:telemetry.attach_many(
  "my-handler",
  [
    [:ethercat, :master, :state],
    [:ethercat, :master, :connect],
    [:ethercat, :master, :sync_slaves],
    [:ethercat, :master, :activate],
    [:ethercat, :domain, :terminate],
    [:ethercat, :slave, :terminate]
  ],
  &handle_event/4,
  nil
)

def handle_event(event, measurements, metadata, _config) do
  Logger.info("EtherCAT", event: event, measurements: measurements, metadata: metadata)
end
```

## Prometheus Integration

```elixir
defmodule MyApp.EtherCATMetrics do
  use Prometheus.Metric

  def setup do
    Counter.declare(
      name: :ethercat_state_transitions_total,
      help: "Master state transitions",
      labels: [:state]
    )

    Histogram.declare(
      name: :ethercat_connect_duration_microseconds,
      help: "Connection duration",
      labels: [:result],
      buckets: [10, 100, 1_000, 10_000, 100_000]
    )

    :telemetry.attach_many("prometheus-ethercat", events(), &handle/4, nil)
  end

  defp events do
    [
      [:ethercat, :master, :state],
      [:ethercat, :master, :connect],
      [:ethercat, :master, :sync_slaves],
      [:ethercat, :master, :activate]
    ]
  end

  def handle([:ethercat, :master, :state], _m, %{state: state}, _c) do
    Counter.inc(name: :ethercat_state_transitions_total, labels: [state])
  end

  def handle([:ethercat, :master, :connect], %{duration: d}, %{result: r}, _c) do
    us = System.convert_time_unit(d, :native, :microsecond)
    Histogram.observe([name: :ethercat_connect_duration_microseconds, labels: [r]], us)
  end

  def handle([:ethercat, :master, :sync_slaves], %{duration: d, count: c}, meta, _c) do
    # Track sync time and slave count
  end

  def handle([:ethercat, :master, :activate], %{duration: d}, meta, _c) do
    # Track activation time, domain/slave counts
  end
end
```

## Typical Event Sequence

```
1. [:ethercat, :master, :state] %{state: :offline}
2. [:ethercat, :master, :connect] %{result: :success, duration: ...}
3. [:ethercat, :master, :state] %{state: :stale}
4. [:ethercat, :master, :sync_slaves] %{count: 3, duration: ...}
5. [:ethercat, :master, :state] %{state: :synced}
6. [:ethercat, :master, :activate] %{domains: 1, slaves: 3, duration: ...}
7. [:ethercat, :master, :state] %{state: :operational}
8. (cyclic operation...)
9. [:ethercat, :domain, :terminate] %{reason: :shutdown, subscriber_count: 2}
10. [:ethercat, :slave, :terminate] %{reason: :shutdown, position: 0, driver: ...}
```

## Best Practices

- **Attach early**: Before starting any EtherCAT operations
- **Convert time**: Use `System.convert_time_unit(duration, :native, :microsecond)`
- **Keep handlers fast**: Offload heavy work to separate processes
- **Check metadata**: Error cases include `:error` key in metadata
- **Structured logging**: Include measurements and metadata for better queries

## References

- [Telemetry](https://hexdocs.pm/telemetry/)
- [Telemetry Metrics](https://hexdocs.pm/telemetry_metrics/)
- [Prometheus.ex](https://hex.pm/packages/prometheus_ex)
