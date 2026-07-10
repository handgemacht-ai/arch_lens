import Config

# arch_lens is a library: it ships no runtime configuration of its own yet.
# Environment-specific overrides live in the matching config/<env>.exs files.
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
