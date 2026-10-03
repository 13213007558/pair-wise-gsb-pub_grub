[![Build Status](https://github.com/jhawthorn/pub_grub/workflows/Test/badge.svg?branch=main)](https://github.com/jhawthorn/pub_grub/actions/workflows/test.yml)

# PubGrub

A ruby implementation of [Natalie Weizenbaum's PubGrub](https://medium.com/@nex3/pubgrub-2fb6470504f), a next-generation version solving algorithm.

It's the resolver used by [Bundler](https://bundler.io) (as of [version 2.4](https://bundler.io/blog/2023/01/31/bundler-v2-4.html)) and [gel](https://github.com/gel-rb/gel).

## Usage

Most users will want to implement their own package source class. See [basic_package_source.rb](https://github.com/jhawthorn/pub_grub/blob/master/lib/pub_grub/basic_package_source.rb) for docs, and the sources from [gel](https://github.com/gel-rb/gel/blob/master/lib/gel/pub_grub/source.rb) and [bundler-explain](https://github.com/jhawthorn/bundler-explain/blob/master/lib/bundler/explain/source.rb) as examples.

A basic example using the built-in StaticPackageSource

``` ruby
source = PubGrub::StaticPackageSource.new do |s|
  s.add 'foo', '2.0.0', deps: { 'bar' => '1.0.0' }
  s.add 'foo', '1.0.0'
  
  s.add 'bar', '1.0.0', deps: { 'foo' => '1.0.0' }
  
  s.root deps: { 'foo' => '>= 1.0.0' }
end

solver = PubGrub::VersionSolver.new(source: source)
solver.solve # => {#<PubGrub::Package :root>=>0, "foo"=>#<Gem::Version "1.0.0">}
```

### Capabilities (virtual packages)

`StaticPackageSource` also supports capabilities: a named feature (with its
own version numbering, independent from any package version) that can be
provided by several real packages. Dependents ask for the capability, and
the solver chooses a provider, backtracking to another provider when the
first choice conflicts downstream.

``` ruby
source = PubGrub::StaticPackageSource.new do |s|
  s.root deps: { 'image-reader' => '>= 2.0' }

  # Each provider declares which capability versions it offers
  s.add 'fast-image', '1.0.0', deps: { 'fast-codec' => '~> 2.0' }, provides: { 'image-reader' => '2.1.0' }
  s.add 'mini-image', '1.0.0', provides: { 'image-reader' => '2.0.0' }, conflicts: ['fast-image']
end

solver = PubGrub::VersionSolver.new(source: source)
solver.solve # => {"image-reader"=>2.1.0 (provided by fast-image), "fast-image"=>1.0.0, ...}

# The final solution split into real packages and capability provisions
solver.solution_report
# => {
#      packages: { "fast-image" => #<Gem::Version "1.0.0">, ... },
#      capabilities: { "image-reader" => { version: 2.1.0, provider: "fast-image", provider_version: 1.0.0 } }
#    }
```

- `provides:` maps capability names to the provided capability version.
  Capability versions are independent from the provider's own versions.
- The solver prefers higher capability versions, and a selected provider's
  own dependencies must still be satisfied.
- `conflicts:` declares mutually exclusive packages which cannot be
  selected together.
- Failure explanations name the providers that were ruled out, e.g.
  `image-reader >= 2.1.0 (provided by fast-image) depends on fast-image = 1.0.0`.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jhawthorn/pub_grub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the PubGrub project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/jhawthorn/pub_grub/blob/main/CODE_OF_CONDUCT.md).

## See Also

* [PubGrub: Next-Generation Version Solving - Natalie Weizenbaum - Medium](https://medium.com/@nex3/pubgrub-2fb6470504f)
* [PubGrub - doc/solver.md - github](https://github.com/dart-lang/pub/blob/master/doc/solver.md)
