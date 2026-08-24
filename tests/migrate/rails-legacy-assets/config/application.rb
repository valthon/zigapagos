require_relative "boot"
module RailsLegacyAssets
  class Application < Rails::Application
    config.load_defaults 6.1
  end
end
