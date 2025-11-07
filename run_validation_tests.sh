#!/bin/bash
echo "====================================="
echo "EtherCAT Functional Validation Tests"
echo "====================================="
echo ""

tests=(
  "108:Bit-level operations"
  "137:Byte-level operations" 
  "192:Rapid state changes"
  "228:PDO subscriptions"
  "278:Multi-PDO concurrent"
  "344:Edge cases"
)

pass=0
fail=0

for test_spec in "${tests[@]}"; do
  line="${test_spec%%:*}"
  name="${test_spec#*:}"
  
  echo "Running: $name (line $line)"
  
  if mix test test/hardware/functional_validation_test.exs:$line --include hardware 2>&1 | grep -q "0 failures"; then
    echo "  ✓ PASSED"
    ((pass++))
  else
    echo "  ✗ FAILED"
    ((fail++))
  fi
  
  # Wait for proper cleanup
  sleep 2
  echo ""
done

echo "====================================="
echo "Results: $pass passed, $fail failed"
echo "====================================="
