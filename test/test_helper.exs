# Only run tmux tests if MIX_USE_TMUX=true is set
# By default, we'll skip tmux tests
run_tmux_tests = System.get_env("MIX_USE_TMUX") == "true"

# Exclude tmux tests unless explicitly enabled
exclude = if !run_tmux_tests, do: [:skip, tmux: true], else: [:skip]
ExUnit.start(exclude: exclude)

# Load support files
Application.ensure_all_started(:mcp)
support_path = Path.expand("support/endpoint_case.ex", __DIR__)
Code.require_file(support_path, "test")
