# bells

**B**anana **E**xtraction **L**ose-**L**ose **S**ynergizer

Development tooling for dd-trace-rb.

## Setup

```bash
bundle install
export GITHUB_TOKEN=your_token
```

## Run

```bash
# Production
bundle exec puma

# Development (auto-reload)
bundle exec rerun -- puma
```

Visit http://localhost:9292

## Test

```bash
bundle exec rspec
```

## License

MIT
