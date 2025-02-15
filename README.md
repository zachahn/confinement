# Confinement

A static site generator for when you're stuck at home.

Assets are generated through the (nightly) [Parcel bundler][parcel2].


## Installation

Confinement requires Ruby 2.7+, Node 10+, and Yarn.

Add this line to your application's Gemfile:

```ruby
gem "confinement"
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install confinement


## Usage

```sh
confinement init path/to/new/site
cd path/to/new/site
confinement server # or confinement build
```


## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run
`rake test` to run the tests. You can also run `bin/console` for an interactive
prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To
release a new version, update the version number in `version.rb`, and then run
`bundle exec rake release`, which will create a git tag for the version, push
git commits and tags, and push the `.gem` file to
[rubygems.org](https://rubygems.org).


## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/zachahn/confinement.


## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).


[parcel2]: https://github.com/parcel-bundler/parcel/tree/v2
