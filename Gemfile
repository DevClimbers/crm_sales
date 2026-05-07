source "https://rubygems.org"

gem "rails", "~> 8.1.2"
gem "propshaft"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "jbuilder"
gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "bootsnap", require: false

# Autenticación
gem "bcrypt", "~> 3.1.7"

# Background jobs
gem "sidekiq"
gem "sidekiq-cron"
gem "redis"

# Paginación
gem "kaminari"

# APIs externas
gem "anthropic"
gem "httparty"

# Frontend
gem "tailwindcss-rails"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "dotenv-rails"
end

group :development do
  gem "web-console"
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end
