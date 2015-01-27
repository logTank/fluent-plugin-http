# -*- encoding: utf-8 -*-

Gem::Specification.new do |gem|
  gem.name          = "fluent-plugin-logtank-http"
  gem.version       = '0.0.4'

  gem.authors       = ["Peter Grman"]
  gem.email         = ["peter.grman@gmail.com"]
  gem.summary       = "enhanced input plugin for HTTP"
  gem.description   = "enhanced input plugin for HTTP based on fluentd's HTTP plugin in core"
  gem.homepage      = "https://github.com/logtank/fluent-plugin-http"

  gem.files         = `git ls-files`.split($\)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]
  gem.has_rdoc      = false

  gem.license = "Apache License 2.0"

  gem.required_ruby_version = '>= 2.1'

  gem.add_runtime_dependency "fluentd"
  gem.add_runtime_dependency("http_parser.rb", [">= 0.5.1", "< 0.7.0"])
  gem.add_runtime_dependency("cool.io", [">= 1.2.2", "< 2.0.0"])

  gem.add_development_dependency("rake")
  gem.add_development_dependency("simplecov")
end