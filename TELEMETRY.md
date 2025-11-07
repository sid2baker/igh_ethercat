# Telemetry Events

This document describes all telemetry events emitted by the EtherCAT library.

## Overview

The EtherCAT library emits telemetry events for monitoring, metrics collection, and observability. All events follow the `:telemetry` specification and can be consumed using `:telemetry.attach/4` or `:telemetry.attach_many/4`.

## Event Reference

### Master Events

#### `[:ethercat, :master, :state]`

Emitted whenever the Master state machine transitions to a new state.

**Measurements:** None (empty map)

**Metadata:**
- `:state` - The current state (`:offline`, `:stale`, `:synced`, `:operational`)

**Example:**
```elixir
:telemetry.attach(
  "master-state-handler",
  [:ethercat, :master, :state],
  fn _event, _measurements, metadata, _config ->
    IO.puts("Master entered state: #{metadata.state}")
  end,
  nil
)
```

#### `[:ethercat, :master, :connect]`

Emitted when attempting to connect the master to the EtherCAT network.

**Measurements:**
- `:duration` - Connection attempt duration in native time units

**Metadata:**
- `:result` - Connection result (`:success`, `:link_down`, or `:error`)
- `:error` - Error description (only present if result is `:error`)

**Example:**
```elixir
:telemetry.attach(
  "master-connect-handler",
  [:ethercat, :master, :connect],
  fn _event, measurements, metadata, _config ->
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    IO.puts("Connect #{metadata.result} in #{duration_ms}ms")
  end,
  nil
)
```

#### `[:ethercat, :master, :sync_slaves]`

Emitted when synchronizing slaves on the bus.

**Measurements:**
- `:duration` - Synchronization duration in native time units
- `:count` - Number of slaves synchronized (only on success)

**Metadata:**
- `:result` - Sync result (`:success` or `:error`)
- `:error` - Error description (only present if result is `:error`)

**Example:**
```elixir
:telemetry.attach(
  "master-sync-handler",
  [:ethercat, :master, :sync_slaves],
  fn _event, measurements, metadata, _config ->
    if metadata.result == :success do
      IO.puts("Synchronized #{measurements.count} slaves")
    end
  end,
  nil
)
```

#### `[:ethercat, :master, :activate]`

Emitted when the master is activated for cyclic operation.

**Measurements:**
- `:duration` - Activation duration in native time units

**Metadata:**
- `:domains` - Number of domains activated
- `:slaves` - Number of slaves activated
- `:result` - Activation result (only present on error: `:error`)
- `:error` - Error description (only present if result is `:error`)

**Example:**
```elixir
:telemetry.attach(
  "master-activate-handler",
  [:ethercat, :master, :activate],
  fn _event, measurements, metadata, _config ->
    duration_us = System.convert_time_unit(measurements.duration, :native, :microsecond)
    IO.puts("Activated #{metadata.slaves} slaves, #{metadata.domains} domains in #{duration_us}µs")
  end,
  nil
)
```

### Domain Events

#### `[:ethercat, :domain, :terminate]`

Emitted when a domain process is terminating.

**Measurements:**
- `:subscriber_count` - Number of active subscribers when terminating

**Metadata:**
- `:reason` - Termination reason

**Example:**
```elixir
:telemetry.attach(
  "domain-terminate-handler",
  [:ethercat, :domain, :terminate],
  fn _event, measurements, metadata, _config ->
    IO.puts("Domain terminating (#{metadata.reason}) with #{measurements.subscriber_count} subscribers")
  end,
  nil
)
```

### Slave Events

#### `[:ethercat, :slave, :terminate]`

Emitted when a slave process is terminating.

**Measurements:**
- `:position` - Bus position of the slave

**Metadata:**
- `:reason` - Termination reason
- `:driver` - Driver module used by the slave

**Example:**
```elixir
:telemetry.attach(
  "slave-terminate-handler",
  [:ethercat, :slave, :terminate],
  fn _event, measurements, metadata, _config ->
    IO.puts("Slave #{measurements.position} (#{metadata.driver}) terminating: #{metadata.reason}")
  end,
  nil
)
```

## Integration Examples

### Prometheus Metrics

```elixir
defmodule MyApp.EtherCATMetrics do
  use Prometheus.Metric

  def setup do
    Counter.declare(
      name: :ethercat_master_state_transitions_total,
      help: "Total number of master state transitions",
      labels: [:state]
    )

    Histogram.declare(
      name: :ethercat_master_connect_duration_microseconds,
      help: "Master connection duration",
      labels: [:result],
      buckets: [10, 100, 1_000, 10_000, 100_000]
    )

    # Attach telemetry handlers
    :telemetry.attach_many(
      "prometheus-ethercat",
      [
        [:ethercat, :master, :state],
        [:ethercat, :master, :connect]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:ethercat, :master, :state], _measurements, %{state: state}, _config) do
    Counter.inc(name: :ethercat_master_state_transitions_total, labels: [state])
  end

  def handle_event([:ethercat, :master, :connect], %{duration: duration}, %{result: result}, _config) do
    duration_us = System.convert_time_unit(duration, :native, :microsecond)
    Histogram.observe([name: :ethercat_master_connect_duration_microseconds, labels: [result]], duration_us)
  end
end
```

### Custom Logger

```elixir
defmodule MyApp.EtherCATLogger do
  require Logger

  def attach do
    events = [
      [:ethercat, :master, :state],
      [:ethercat, :master, :connect],
      [:ethercat, :master, :sync_slaves],
      [:ethercat, :master, :activate],
      [:ethercat, :domain, :terminate],
      [:ethercat, :slave, :terminate]
    ]

    :telemetry.attach_many("ethercat-logger", events, &handle_event/4, nil)
  end

  def handle_event(event, measurements, metadata, _config) do
    Logger.info("EtherCAT Event: #{inspect(event)}",
      measurements: measurements,
      metadata: metadata
    )
  end
end
```

### Application Start

Add telemetry handlers in your application start:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    # Attach telemetry handlers before starting EtherCAT
    MyApp.EtherCATMetrics.setup()
    MyApp.EtherCATLogger.attach()

    children = [
      # ... your supervision tree
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Best Practices

1. **Attach Early**: Attach telemetry handlers during application startup, before any EtherCAT operations occur.

2. **Use attach_many**: When monitoring multiple events, use `:telemetry.attach_many/4` to attach a single handler to multiple events.

3. **Convert Time Units**: Always convert duration measurements from `:native` time units to a human-readable unit (microseconds, milliseconds) for metrics and logging.

4. **Handle Errors**: Check for the presence of error metadata and handle error cases appropriately in your handlers.

5. **Avoid Blocking**: Keep telemetry handlers fast and non-blocking. Offload heavy work to separate processes if needed.

6. **Structured Logging**: Use structured logging with measurements and metadata for better observability and querying.

## Event Lifecycle

Here's a typical event sequence for a complete EtherCAT session:

1. `[:ethercat, :master, :state]` - `:offline`
2. `[:ethercat, :master, :connect]` - Connection attempt
3. `[:ethercat, :master, :state]` - `:stale`
4. `[:ethercat, :master, :sync_slaves]` - Slave discovery
5. `[:ethercat, :master, :state]` - `:synced`
6. `[:ethercat, :master, :activate]` - Activation for cyclic operation
7. `[:ethercat, :master, :state]` - `:operational`
8. (During operation) - Cyclic data exchange
9. (On shutdown) - `[:ethercat, :domain, :terminate]` and `[:ethercat, :slave, :terminate]` events

## See Also

- [Telemetry Documentation](https://hexdocs.pm/telemetry/)
- [Telemetry Metrics](https://hexdocs.pm/telemetry_metrics/)
- [Prometheus.ex](https://hex.pm/packages/prometheus_ex)
