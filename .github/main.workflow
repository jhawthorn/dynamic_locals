workflow "Run tests on push" {
  on = "push"
  resolves = ["Run tests"]
}

action "Run tests" {
  uses = "docker://ruby"
  runs = ["sh", "-c", "bundle install -j8 && bundle exec rake test"]
}
