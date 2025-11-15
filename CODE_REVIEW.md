# Code Review - EtherCAT Master Refactor

## Overview

This document reviews the refactored EtherCAT architecture, validating design decisions, identifying potential issues, and suggesting improvements.

## Architecture Assessment

### ✅ Strengths

1. **Clear State Machine (gen_statem)**
   - Explicit states: `:offline → :scanning → :ready → :operational`
   - State enter callbacks for clear logging
   - State-specific event handling prevents invalid transitions

2. **Simplified Domain Management**
   - Domains reduced to `%{ref, interval}` (no processes)
   - Eliminates inter-process communication overhead
   - Clear ownership: Master owns domains

3. **Correct Subscriber Pattern**
   - `%{{domain_name, unique_name} => [pids]}` matches NIF exactly
   - No string parsing during notification
   - Direct lookup: O(1) subscriber notification

4. **Driver Process Model**
   - Drivers are GenServers (own state, lifecycle)
   - Clean separation: config vs runtime
   - Flexible: can be gen_statem, GenServer, or Agent

5. **Hardware Diff Tracking**
   - Built-in expected vs actual comparison
   - Tree diff algorithm for nested structures
   - Useful for debugging configuration mismatches

### ⚠️ Potential Issues

#### 1. **PDO Registration Flow**

**Current Code:**
```elixir
defp register_pdo_entries(data, position, slave_info, pdo_configs) do
  {:ok, slave_config} = get_slave_config_for_position(data, position)

  Enum.each(pdo_configs, fn pdo_config ->
    domain_name = Map.get(pdo_config, :domain, :default_domain)

    case data.domains[domain_name] do
      nil ->
        Logger.warning("Slave #{position}: Domain #{domain_name} not found...")
      domain_info ->
        register_pdo_to_domain(...)
    end
  end)

  :ok  # Always returns :ok even if domains missing!
end
```

**Issue:** Silently skips PDOs if domain doesn't exist. Should fail fast.

**Recommendation:**
```elixir
defp register_pdo_entries(data, position, slave_info, pdo_configs) do
  Enum.reduce_while(pdo_configs, :ok, fn pdo_config, :ok ->
    domain_name = Map.get(pdo_config, :domain, :default_domain)

    case data.domains[domain_name] do
      nil ->
        {:halt, {:error, {:domain_not_found, domain_name}}}
      domain_info ->
        register_pdo_to_domain(...)
        {:cont, :ok}
    end
  end)
end
```

#### 2. **Default Domain Creation**

**Current Code:** Master does NOT auto-create `:default_domain`

**Issue:** Generic driver assumes `:default_domain` exists:
```elixir
domain = :default_domain  # Might not exist!
result = Master.subscribe(state.master, domain, unique_name, subscriber)
```

**Recommendation:** Auto-create `:default_domain` in Master init:
```elixir
def init(opts) do
  # ... existing code ...
  {:ok, :offline, data, [
    {:next_event, :internal, :connect},
    {:next_event, :internal, :create_default_domain}
  ]}
end

def offline(:internal, :create_default_domain, data) do
  case Nif.master_create_domain(data.master_ref, self(), 1000) do
    {:ok, domain_ref} ->
      :ok = Nif.domain_set_pid(domain_ref, self())
      domain_info = %{ref: domain_ref, interval: 1000}
      new_domains = Map.put(data.domains, :default_domain, domain_info)
      {:keep_state, %{data | domains: new_domains}}
    {:error, _} ->
      # Continue anyway, might be created later
      :keep_state_and_data
  end
end
```

#### 3. **Subscriber Cleanup on :DOWN**

**Current Code:**
```elixir
def ready(:info, {:DOWN, _ref, :process, pid, _reason}, data) do
  new_subscribers =
    Map.new(data.subscribers, fn {key, pids} ->
      updated = List.delete(pids, pid)
      if updated == [], do: nil, else: {key, updated}
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()

  {:keep_state, %{data | subscribers: new_subscribers}}
end
```

**Issue:** Inefficient - rebuilds entire subscribers map even if pid only in one subscription.

**Recommendation:**
```elixir
def ready(:info, {:DOWN, _ref, :process, pid, _reason}, data) do
  # Only update entries that contain this pid
  new_subscribers =
    Enum.reduce(data.subscribers, data.subscribers, fn {key, pids}, acc ->
      if pid in pids do
        updated = List.delete(pids, pid)
        if updated == [], do: Map.delete(acc, key), else: Map.put(acc, key, updated)
      else
        acc
      end
    end)

  {:keep_state, %{data | subscribers: new_subscribers}}
end
```

Or even better - track which subscriptions a pid has:
```elixir
# Add to state:
pid_to_subscriptions: %{pid() => [{domain_name, unique_name}]}

# On :DOWN:
case data.pid_to_subscriptions[pid] do
  nil -> :keep_state_and_data
  keys ->
    new_subscribers = Enum.reduce(keys, data.subscribers, fn key, acc ->
      updated = List.delete(acc[key], pid)
      if updated == [], do: Map.delete(acc, key), else: Map.put(acc, key, updated)
    end)
    new_pid_map = Map.delete(data.pid_to_subscriptions, pid)
    {:keep_state, %{data | subscribers: new_subscribers, pid_to_subscriptions: new_pid_map}}
end
```

#### 4. **Error Handling in configure_single_slave**

**Current Code:**
```elixir
Enum.each(sdo_configs, fn {index, subindex, sdo_data} ->
  case Nif.slave_config_sdo(...) do
    :ok -> Logger.debug(...)
    {:error, reason} -> Logger.warning(...)  # Continues anyway!
  end
end)
```

**Issue:** SDO failures are logged but don't stop configuration. Device might be misconfigured.

**Recommendation:** Add strict mode option:
```elixir
strict_mode = Keyword.get(opts, :strict_sdo_config, false)

result = Enum.reduce_while(sdo_configs, :ok, fn {index, subindex, data}, :ok ->
  case Nif.slave_config_sdo(...) do
    :ok -> {:cont, :ok}
    {:error, reason} = error ->
      Logger.warning("SDO failed...")
      if strict_mode do
        {:halt, error}
      else
        {:cont, :ok}  # Continue in lenient mode
      end
  end
end)
```

#### 5. **NIF Data Change Format**

**Assumption:** NIF sends `{:data_changed, domain_ref, unique_name, value}`

**Current Code:** Has fallback for 2-tuple format:
```elixir
def operational(:info, {:data_changed, unique_name, value}, data) do
  domain_name = :default_domain  # Assumes default!
  ...
end
```

**Recommendation:** Document NIF contract in module docs:
```elixir
@moduledoc """
...

## NIF Contract

### Data Change Notifications

NIF MUST send:
  {:data_changed, domain_ref, unique_name, binary_value}

Where:
- domain_ref: Domain reference (from master_create_domain)
- unique_name: Entry identifier "slave_X:pdo:entry"
- binary_value: Raw PDO value

Fallback for legacy NIF (assumes default_domain):
  {:data_changed, unique_name, binary_value}
"""
```

## Correctness Assessment

### State Machine Validity

✅ **Offline State**
- Only accepts :connect event
- Transitions to :scanning on link_up
- Properly handles retry on failure

✅ **Scanning State**
- Auto-discovers slaves
- Starts driver processes
- Transitions to :ready
- Fallback to :offline on error

✅ **Ready State**
- Accepts domain creation
- Accepts slave configuration (start_cyclic)
- Accepts subscriptions
- Transitions to :operational on activation

✅ **Operational State**
- Accepts read/write
- Handles data_changed notifications
- Accepts stop_cyclic (back to :ready)
- Properly cleans up cyclic task

### Race Conditions

⚠️ **Slave Process Crash During Configuration**

If a slave crashes during `configure_all_slaves`:
```elixir
defp configure_all_slaves(data) do
  Enum.reduce_while(data.slaves, :ok, fn {position, slave_info}, :ok ->
    # What if slave_info.pid crashes here?
    case configure_single_slave(data, position, slave_info) do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end)
end
```

**Recommendation:** Add process monitor during configuration:
```elixir
defp configure_all_slaves(data) do
  # Monitor all slaves before configuration
  refs = Enum.map(data.slaves, fn {_pos, info} ->
    {info.pid, Process.monitor(info.pid)}
  end)

  result = Enum.reduce_while(data.slaves, :ok, fn {position, slave_info}, :ok ->
    receive do
      {:DOWN, _ref, :process, pid, reason} when pid == slave_info.pid ->
        {:halt, {:error, {:slave_crashed, position, reason}}}
    after
      0 ->
        case configure_single_slave(data, position, slave_info) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
    end
  end)

  # Demonitor all
  Enum.each(refs, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)

  result
end
```

### Memory Leaks

✅ **Subscriber Cleanup**
- Process.monitor called on subscribe
- :DOWN handled in all states
- Subscribers removed correctly

⚠️ **Domain Cleanup**
- Domain refs never cleaned up (no delete_domain function)
- If many domains created/destroyed, refs accumulate

**Recommendation:**
```elixir
def delete_domain(master \\ __MODULE__, domain_name) do
  :gen_statem.call(master, {:delete_domain, domain_name})
end

def ready({:call, from}, {:delete_domain, domain_name}, data) do
  case data.domains[domain_name] do
    nil ->
      {:keep_state_and_data, [{:reply, from, {:error, :not_found}}]}
    domain_info ->
      # TODO: Call NIF to destroy domain
      # Nif.master_destroy_domain(domain_info.ref)
      new_domains = Map.delete(data.domains, domain_name)
      {:keep_state, %{data | domains: new_domains}, [{:reply, from, :ok}]}
  end
end
```

## Performance Considerations

### Subscriber Notification

**Current:** Linear scan of subscriber list (acceptable for small lists)
```elixir
Enum.each(pids, fn pid -> send(pid, {...}) end)
```

**Optimization (if needed):** Batch notifications or parallel send:
```elixir
Task.async_stream(pids, fn pid -> send(pid, {...}) end, max_concurrency: 10)
|> Stream.run()
```

### PDO Registration

**Current:** Sequential registration
```elixir
Enum.each(pdo_configs, fn pdo_config ->
  Enum.each(pdo_config.entries, fn entry ->
    Nif.slave_config_reg_pdo_entry(...)
  end)
end)
```

**Optimization:** Batch NIF calls if supported

## Security Considerations

✅ **Process Isolation**
- Each slave is separate process
- Crash doesn't affect others
- Supervision tree properly handles failures

⚠️ **NIF Reference Safety**
- Master holds NIF references
- If Master crashes, NIF resources leak?
- Need NIF resource cleanup on terminate

**Recommendation:** Ensure NIF resources auto-cleanup or add explicit cleanup:
```elixir
def terminate(reason, _state, data) do
  # Cleanup NIF resources
  Nif.master_release(data.master_ref)
  Enum.each(data.domains, fn {_name, info} ->
    Nif.domain_release(info.ref)
  end)
  :ok
end
```

## Testing Recommendations

1. **State Machine Tests**
   - Test all valid transitions
   - Test invalid transitions (should stay in current state)
   - Test error recovery

2. **Subscriber Tests**
   - Subscribe/unsubscribe
   - Multiple subscribers to same entry
   - Subscriber crash cleanup
   - Notification delivery

3. **PDO Configuration Tests**
   - Valid configuration
   - Missing domain error
   - Slave crash during config
   - SDO failure handling

4. **Concurrency Tests**
   - Multiple slaves configuring in parallel
   - Read/write under load
   - Subscribe during operation
   - Stop/start cyclic mode

## Conclusion

### Overall Rating: ⭐⭐⭐⭐☆ (4/5)

**Strengths:**
- Clean architecture
- Correct state machine
- Efficient subscriber pattern
- Good separation of concerns

**Areas for Improvement:**
- Error handling in PDO registration (fail fast)
- Auto-create default domain
- Optimize subscriber cleanup
- Document NIF contract
- Add strict mode for SDO config
- Resource cleanup in terminate

### Priority Fixes

1. **High:** Auto-create `:default_domain` on init
2. **High:** Fail-fast on missing domain in PDO registration
3. **Medium:** Optimize subscriber cleanup (track reverse mapping)
4. **Medium:** Document NIF data_changed format
5. **Low:** Add domain deletion
6. **Low:** Batch PDO registration if NIF supports it

### Next Steps

1. Implement priority fixes
2. Write comprehensive test suite
3. Port device-specific drivers (EL3202, etc.)
4. Create high-level System API wrapper
5. Performance profiling with real hardware
