# DynamicLocals

This is an experimental Ruby to Ruby transpiler which swaps out the functionality of local variables, allowing them to be dynamically defined.

This is a proof of concept and shouldn't be used yet.

## Usage

``` ruby
c = Class.new do
  def foo
    "from method"
  end
end

src = DynamicLocals.translate("foo")
# => "locals.fetch(:foo) { foo() }"

c.class_eval("def run(locals); #{src}; end")

c.new.run({})
#=> "from method"
c.new.run({ foo: "from local" })
#=> "from local"
```

## Why?

ActionView has the interesting quality that the local variables defined within a template are defined by the caller.

```
<%= render partial: "some_template", locals: { foo: "bar" } %>
```

This is tricky, because local variables are determined by Ruby at compile time.
Because method calls with no arguments look the same as local variable accesses, it's ambiguous which they are. Ruby determines between calls and locals by checking if the local is being assigned to at

ActionView currently solves this by compiling a separate template for each set of local variable names passed in. This wastes memory by duplicating the template for every set of locals being passed in and also prevents templates from being compiled at boot, since we don't know what locals they will be given.

## How?

The basic mechanism is to replace all ambiguous access a hash fetch falling back to an unambiguous method call:

``` ruby
locals.fetch(:foobar) { foobar() }
```

This introduces a number of corner cases (see tests for many examples), which this also tries to work around.
The goal of this is for Ruby's behaviour to be unchanged and not to leak this "optimization".

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jhawthorn/dynamic_locals. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the DynamicLocals project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/jhawthorn/dynamic_locals/blob/master/CODE_OF_CONDUCT.md).
