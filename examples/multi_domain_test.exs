#!/usr/bin/env elixir

# Multi-Domain Timing Test
# This script tests the timing behavior of :fast and :slow domains

alias Examples.SimpleIOTest, as: IOTest

IO.puts("""
========================================
Multi-Domain Timing Diagnostic Test
========================================

Domain Configuration:
  :fast  → interval=1   (10ms/cycle)
  :slow  → interval=200 (2000ms/cycle)

Output Assignment:
  Odd channels (1,3,5,7,9,11,13,15) → :fast
  Even channels (2,4,6,8,10,12,14,16) → :slow

Input Assignment:
  Channels 1-8 → :fast
  Channels 9-16 → :slow

========================================
""")

# Clear all outputs first
IO.puts("\nClearing all outputs...")
IOTest.set_all_outputs(List.duplicate(false, 16))
Process.sleep(100)

# Test 1: Fast domain output → fast domain input (should work immediately)
IO.puts("\n--- Test 1: Fast → Fast ---")
IO.puts("Setting output 0 (channel_1, odd, :fast domain)...")
IOTest.set_output(0, true)

IO.puts("Waiting 50ms for fast domain cycle...")
Process.sleep(50)

case IOTest.get_input(0) do
  {:ok, true} -> IO.puts("✓ PASS: Input 0 (channel_1, :fast) is HIGH")
  {:ok, false} -> IO.puts("✗ FAIL: Input 0 still LOW (wiring issue or domain not cycling?)")
  error -> IO.puts("✗ ERROR: #{inspect(error)}")
end

# Test 2: Slow domain output → fast domain input (2 second delay expected)
IO.puts("\n--- Test 2: Slow → Fast ---")
IO.puts("Setting output 1 (channel_2, even, :slow domain)...")
IOTest.set_output(1, true)

IO.puts("Waiting 100ms...")
Process.sleep(100)

case IOTest.get_input(1) do
  {:ok, true} -> IO.puts("✓ Input 1 already HIGH (unexpected!)")
  {:ok, false} -> IO.puts("○ Input 1 still LOW (expected - slow domain hasn't cycled yet)")
  error -> IO.puts("✗ ERROR: #{inspect(error)}")
end

IO.puts("Waiting additional 2.2 seconds for slow domain cycle...")
Process.sleep(2200)

case IOTest.get_input(1) do
  {:ok, true} -> IO.puts("✓ PASS: Input 1 (channel_2, :fast) is now HIGH after slow domain cycle")
  {:ok, false} -> IO.puts("✗ FAIL: Input 1 still LOW after 2.2s (slow domain not cycling?)")
  error -> IO.puts("✗ ERROR: #{inspect(error)}")
end

# Test 3: Fast domain output → slow domain input
IO.puts("\n--- Test 3: Fast → Slow ---")
IO.puts("Setting output 8 (channel_9, odd, :fast domain)...")
IOTest.set_output(8, true)

IO.puts("Waiting 50ms for fast domain cycle...")
Process.sleep(50)

case IOTest.get_input(8) do
  {:ok, true} -> IO.puts("✓ Input 8 already HIGH (unexpected - slow domain read?)")
  {:ok, false} -> IO.puts("○ Input 8 still LOW (expected - slow domain input hasn't read yet)")
  error -> IO.puts("✗ ERROR: #{inspect(error)}")
end

IO.puts("Waiting additional 2.2 seconds for slow domain to read...")
Process.sleep(2200)

case IOTest.get_input(8) do
  {:ok, true} -> IO.puts("✓ PASS: Input 8 (channel_9, :slow) is now HIGH")
  {:ok, false} -> IO.puts("✗ FAIL: Input 8 still LOW (slow domain not reading?)")
  error -> IO.puts("✗ ERROR: #{inspect(error)}")
end

# Test 4: Slow output → slow input
IO.puts("\n--- Test 4: Slow → Slow ---")
IO.puts("Setting output 9 (channel_10, even, :slow domain)...")
IOTest.set_output(9, true)

IO.puts("Waiting 2.2 seconds for slow domain cycle...")
Process.sleep(2200)

case IOTest.get_input(9) do
  {:ok, true} -> IO.puts("✓ PASS: Input 9 (channel_10, :slow) is HIGH")
  {:ok, false} -> IO.puts("✗ FAIL: Input 9 still LOW")
  error -> IO.puts("✗ ERROR: #{inspect(error)}")
end

# Clean up
IO.puts("\n--- Cleanup ---")
IOTest.set_all_outputs(List.duplicate(false, 16))

IO.puts("""

========================================
Test Complete!
========================================
""")
