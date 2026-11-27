# tailwindcss-rails builds app/assets/tailwind/application.css into app/assets/builds/tailwind.css. Here its build and watch
# tasks are replaced so the output goes to vendor/assets/builds/tailwind.css instead. Everything under app/assets/**/*.css is
# linked on EVERY page by `stylesheet_link_tag :app` (and test/integration/stylesheets_test.rb counts those links), so a
# Tailwind + Basecoat build in app/assets/builds would load on the whole site. Only a layout that asks for
# `stylesheet_link_tag "tailwind"` loads it (layouts/basecoat). assets:precompile and test:prepare still run the build: the
# gem hooks them to the task name, which stays.
namespace :tailwindcss do
  BASECOAT_TAILWIND_OUT = "vendor/assets/builds/tailwind.css".freeze

  def self.basecoat_command(debug:, silent:)
    root = Rails.root
    command = [ Tailwindcss::Ruby.executable, "-i", root.join("app/assets/tailwind/application.css").to_s, "-o", root.join(BASECOAT_TAILWIND_OUT).to_s ]
    command << "--minify" unless debug || Rails.application.config.assets.css_compressor.present?
    command << "--silent" if silent
    command
  end

  Rake::Task["tailwindcss:build"].clear if Rake::Task.task_defined?("tailwindcss:build")
  Rake::Task["tailwindcss:watch"].clear if Rake::Task.task_defined?("tailwindcss:watch")
  Rake::Task["tailwindcss:clobber"].clear if Rake::Task.task_defined?("tailwindcss:clobber")

  desc "Build Tailwind + Basecoat into vendor/assets/builds/tailwind.css (not linked by stylesheet_link_tag :app)"
  task build: :environment do |_, args|
    system(*basecoat_command(debug: args.extras.include?("debug"), silent: args.extras.include?("silent")), exception: true)
  end

  desc "Watch and rebuild Tailwind + Basecoat on file changes"
  task watch: :environment do |_, args|
    command = basecoat_command(debug: args.extras.include?("debug"), silent: args.extras.include?("silent")) + [ "-w" ]
    Tailwindcss::ProcessRunner.spawn_and_wait({}, *command)
  end

  desc "Remove the Tailwind + Basecoat build (vendor/assets/builds/*.css)"
  task :clobber do
    rm_rf Dir["vendor/assets/builds/[^.]*.css"], verbose: false
  end
end
