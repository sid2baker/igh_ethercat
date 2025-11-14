# Code Formatting

This project uses Elixir's built-in formatter with the Spark.Formatter plugin to maintain consistent code style and proper ordering of DSL sections.

## Setup

The formatter is configured in `.formatter.exs`:

```elixir
[
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,examples}/**/*.{ex,exs}"]
]
```

## Running the Formatter

Format all files:
```bash
mix format
```

Format a specific file:
```bash
mix format path/to/file.ex
```

Check formatting without making changes:
```bash
mix format --check-formatted
```

## DSL Section Order

The Spark formatter automatically reorders DSL sections according to the configuration in `config/config.exs`.

### EtherCAT.Config Section Order

When writing configuration modules using `EtherCAT.Config`, sections will be automatically ordered as:

1. **`domain`** - Domain definitions (define infrastructure first)
2. **`slave`** - Slave device configurations (use the domains)

Within each `slave` block, subsections are ordered logically:
1. **`driver`** - Driver module specification
2. **`expect`** - Hardware verification (vendor/product IDs)
3. **`config`** - Device-specific configuration
4. **`entry`** - PDO entry mappings to domains

### Example

**Before formatting:**
```elixir
defmodule MyMachine do
  use EtherCAT.Config

  # Slave defined before domains (wrong order)
  slave position: 0, name: :outputs do
    entry :ch1, :value, domain: :fast_loop
    driver EtherCAT.Drivers.EL2809
  end

  domain :fast_loop, interval: 1
end
```

**After running `mix format`:**
```elixir
defmodule MyMachine do
  use EtherCAT.Config

  # Domains moved to the top
  domain :fast_loop, interval: 1

  # Slave sections follow
  slave position: 0, name: :outputs do
    driver EtherCAT.Drivers.EL2809
    entry :ch1, :value, domain: :fast_loop
  end
end
```

## Testing the Formatter

An example configuration file is provided in `examples/example_config.ex` that demonstrates the formatter's section reordering:

```bash
# Format the example file
mix format examples/example_config.ex

# View the changes
git diff examples/example_config.ex
```

## Configuration

The Spark formatter configuration is in `config/config.exs`:

```elixir
config :spark, :formatter,
  remove_parens?: true,
  "EtherCAT.Config": [
    section_order: [
      :domain,
      :slave
    ]
  ]
```

### Options

- **`remove_parens?`**: Automatically removes unnecessary parentheses in DSL macro calls
- **`section_order`**: Defines the ordering of top-level DSL sections

## Benefits

1. **Consistency** - All configuration files follow the same structure
2. **Readability** - Logical ordering (infrastructure before usage)
3. **Maintainability** - Automatic enforcement of style guidelines
4. **Best Practices** - Domains defined before slaves that reference them

## Integration

### Pre-commit Hook

Add formatting to your pre-commit hook:

```bash
#!/bin/sh
mix format --check-formatted
```

### CI/CD

Check formatting in CI:

```bash
mix format --check-formatted
```

This will exit with code 1 if any files need formatting.

## Troubleshooting

### Formatter not reordering sections

1. Ensure `Spark.Formatter` is in the plugins list in `.formatter.exs`
2. Verify `config/config.exs` has the correct section order configuration
3. Check that your module uses `EtherCAT.Config` (not just `Spark.Dsl`)

### Build errors after adding formatter

If you get compilation errors about missing `Spark.Formatter`:

```bash
mix deps.get
mix compile
```

The Spark library includes the formatter plugin, so no additional dependencies are needed.
