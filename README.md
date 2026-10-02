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

### Multiple platforms

`solve_for_platforms` solves all targets in one joint resolution. A package selected
for more than one target has exactly one version in the result.

``` ruby
result = PubGrub.solve_for_platforms([:linux, :macos]) do |s|
  s.root deps: { "app" => "1.0.0" }

  # This version and its dependencies apply on both targets.
  s.add "app", "1.0.0", platform_deps: {
    "linux-only" => { requirement: "1.0.0", platforms: :linux },
    "macos-only" => { requirement: "1.0.0", platforms: :macos }
  }
  s.add "linux-only", "1.0.0", platforms: :linux
  s.add "macos-only", "1.0.0", platforms: :macos
end

result.common     # Packages needed on every target
result[:linux]    # Packages needed only on linux
result[:macos]    # Packages needed only on macos
```

`platforms` limits where a package version is available. `deps` applies on every
platform where that parent version is available; `platform_deps` applies only on
the listed platforms. If no single version satisfies every platform that needs a
package, the failure explanation names those platform conditions.

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
