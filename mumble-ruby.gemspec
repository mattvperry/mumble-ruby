# -*- encoding: utf-8 -*-
require File.expand_path('../lib/mumble-ruby/version', __FILE__)

Gem::Specification.new do |gem|
  gem.authors       = ["Matthew Perry"]
  gem.email         = ["perrym5@rpi.edu"]
  gem.description   = %q{Ruby API for interacting with a mumble server}
  gem.summary       = %q{Implements the mumble VOIP protocol in ruby for more easily writing clients.}
  gem.homepage      = ""

  gem.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  gem.files         = `git ls-files`.split("\n")
  gem.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  gem.name          = "mumble-ruby"
  gem.require_paths = ["lib"]
  gem.version       = Mumble::VERSION

  gem.add_dependency "activesupport"
  gem.add_dependency "celt-ruby"

  gem.add_development_dependency "ruby_protobuf"
end
