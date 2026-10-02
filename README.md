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

## Minimal-change (lockfile-preserving) solving

`PubGrub::MinimalChangeSolver` finds, among all solutions that satisfy
every dependency, one whose total change cost against an existing
lockfile is minimal. This avoids the common problem where upgrading one
direct dependency needlessly rewrites many versions that could have
been kept.

### Cost model

Given the old lockfile and per-package, non-negative costs, a solution
is priced as follows:

* **kept**: package in both lockfile and solution at the *same* version
  costs 0.
* **changed**: package in both, but at a *different* version, costs
  `change_costs[package]`.
* **added**: package in the solution but *not* in the lockfile (newly
  introduced) costs `added_costs[package]`.
* **removed**: package in the lockfile but *not* in the solution (no
  longer required) costs `removed_costs[package]`.

Packages missing from a cost hash default to a cost of 1. Negative
costs are rejected.

``` ruby
solver = PubGrub::MinimalChangeSolver.new(
  source: source,
  lockfile: { "foo" => Gem::Version.new("1.0.0") },
  change_costs: { "foo" => 1 },
  added_costs: Hash.new(5),
  removed_costs: Hash.new(2),
  max_solves: 1000, # search budget
)
result = solver.solve

result.solution # => {package => version, ...}
result.cost     # => total change cost of the solution
result.status   # => :optimal or :feasible
```

### Optimality, search budget, and the two result states

Simply preferring locked versions during solving is a heuristic, not a
guarantee: keeping an old version of one package can force expensive
changes elsewhere. `MinimalChangeSolver` therefore runs a
branch-and-bound search over PubGrub solutions with per-node cost lower
bounds, and only reports `:optimal` once the search space is exhausted
-- i.e. it has been *proven* that no cheaper solution exists.

If the `max_solves` budget runs out first, the best solution found so
far is returned with status `:feasible`: a valid, usable set of
versions whose optimality is *not* proven. Callers must check
`result.status` (or `result.optimal?`) to distinguish "proven no
cheaper solution exists" from "merely the best found so far".

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
