require_relative "boot"
module RailsPresentation
  class Application < Rails::Application
    config.load_defaults 7.2
    config.i18n.default_locale = :en
  end
end
