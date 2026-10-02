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

### Solving several platforms with one lockfile

`MultiPlatformPackageSource` solves multiple target platforms (for example
Linux and macOS) in a single pass. It never solves each platform separately
and merges the results: a package needed on more than one platform must pick
the exact same version everywhere. Versions can declare the platforms on
which they are available, and dependencies can declare the platforms on
which they take effect.

``` ruby
source = PubGrub::MultiPlatformPackageSource.new(:linux, :macos) do |s|
  s.root linux: { 'app' => '1.0.0' }, macos: { 'app' => '1.0.0' }

  s.add 'app', '1.0.0', deps: {
    'shared' => '>= 1.0',
    # Platform-only dependency
    'kqueue' => s.on(:macos) { '~> 1.0' }
  }

  s.add 'shared', '1.2.0'
  # A version available on one platform only
  s.add 'kqueue', '1.0.0', platforms: [:macos]
end

result = PubGrub.solve_for_platforms(source)
result.common   # {"app"=>#<Gem::Version "1.0.0">, "shared"=>#<Gem::Version "1.2.0">}
result.only_on  # {:macos=>{"kqueue"=>#<Gem::Version "1.0.0">}}
result.for_platform(:linux) # shared + platform-only packages for linux
```

If no single set of versions satisfies every platform, a `PubGrub::SolveFailure`
is raised whose explanation names the conflicting platform conditions.

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
