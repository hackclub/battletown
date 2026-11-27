# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
# Basecoat 1.3.0 (MIT, vendor/basecoat/VERSION). preload: false keeps it out of every page head; only layouts/basecoat imports it.
pin "basecoat", preload: false
