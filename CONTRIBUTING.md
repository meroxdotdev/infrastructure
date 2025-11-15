# Contributing Guidelines

Thank you for considering contributing to this infrastructure repository!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/infrastructure.git`
3. Create a branch: `git checkout -b feature/your-feature-name`
4. Make your changes
5. Test your changes
6. Commit using [Conventional Commits](https://www.conventionalcommits.org/)
7. Push to your fork: `git push origin feature/your-feature-name`
8. Open a Pull Request

## Development Setup

### Prerequisites
- Install tools via Mise: `mise install`
- Ensure you have access to the cluster (for testing)

## Code Standards

### Commit Messages
Follow [Conventional Commits](https://www.conventionalcommits.org/):
- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation changes
- `style:` Code style changes (formatting, etc.)
- `refactor:` Code refactoring
- `test:` Adding or updating tests
- `chore:` Maintenance tasks

Examples:
```
feat(kubernetes): add new monitoring app
fix(scripts): correct bootstrap script error
docs(readme): update installation instructions
```

### YAML Files
- Use 2 spaces for indentation
- Keep lines under 200 characters when possible
- Use meaningful comments
- Follow existing patterns

### Shell Scripts
- Use `set -Eeuo pipefail` at the start
- Quote all variables
- Use `[[ ]]` for conditionals
- Follow existing script patterns

### Kubernetes Manifests
- Use consistent naming conventions
- Include appropriate labels
- Add resource limits where applicable
- Document complex configurations

## Testing

### Before Submitting
- [ ] Test scripts locally
- [ ] Verify YAML syntax: `yamllint` or `kubeval`
- [ ] Check for secrets: Ensure no unencrypted secrets
- [ ] Review your changes: `git diff`

### Kubernetes Changes
- Test in a development environment first
- Verify resources apply correctly: `kubectl apply --dry-run=client`
- Check Flux reconciliation: `flux get kustomizations`

## Pull Request Process

1. **Update Documentation**: If you're adding features, update relevant docs
2. **Add Tests**: If applicable, add tests for new functionality
3. **Update CHANGELOG**: Add entry for significant changes
4. **Ensure CI Passes**: All GitHub Actions must pass
5. **Request Review**: Tag relevant maintainers

### PR Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Comments added for complex code
- [ ] Documentation updated
- [ ] No new warnings or errors
- [ ] Tests pass (if applicable)
- [ ] Dependencies updated (if applicable)

## Review Process

- Maintainers will review your PR
- Address any feedback promptly
- Be open to suggestions and improvements
- Keep PRs focused and reasonably sized

## Questions?

- Open a discussion for general questions
- Check existing issues before creating new ones
- Be respectful and constructive in all interactions

Thank you for contributing! 🎉

