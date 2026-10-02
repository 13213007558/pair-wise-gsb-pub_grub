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

## Minimal-change solving

When re-resolving against an existing lockfile, any valid solution is not
enough: you usually want the solution that changes the lockfile the
least. `PubGrub::MinimalChangeSolver` takes the previous lockfile plus a
non-negative change cost per package and searches for a solution with the
lowest total cost.

``` ruby
solver = PubGrub::MinimalChangeSolver.new(
  source: source,
  locked: { "foo" => Gem::Version.new("1.0.0") }, # previous lockfile
  costs: { "foo" => 5 },                          # per-package weight, default 1
  max_nodes: 1000,                                # optional search budget
)
result = solver.solve

result.solution # => {"foo"=>#<Gem::Version "1.0.0">, ...} (root not included)
result.cost     # => 0
result.status   # => :optimal (proven cheapest) or :feasible (best so far)
result.optimal? # => true
```

### Cost model

The cost of a solution is the sum over all packages (in the solution, the
lockfile, or both) of:

* **0** if the package keeps its locked version
* **cost(package)** if the package is locked but selected at a different version
* **cost(package)** if the package is **added** (selected, but not locked)
* **cost(package)** if the package is **removed** (locked, but not selected)

Costs default to 1 and must be non-negative. Locked versions are compared
with `==`, so they should be the same objects the package source returns.

### Optimality

Preferring locked versions is only a heuristic — keeping an old version of
one package can force more expensive changes elsewhere. The solver
therefore runs a branch-and-bound search (using PubGrub to complete each
partial assignment) and only reports `status == :optimal` once every
branch that could still hide a strictly cheaper solution has been explored
or pruned by an admissible lower bound.

If the `max_nodes` budget runs out first, the cheapest solution found so
far is returned with `status == :feasible` (`optimal? == false`): a
valid, usable set of versions, but a cheaper one may still exist.

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
