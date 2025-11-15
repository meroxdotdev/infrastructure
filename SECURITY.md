# Security Policy

## Supported Versions

We actively support the following versions with security updates:

| Version | Supported          |
| ------- | ------------------ |
| Latest  | :white_check_mark: |
| < Latest| :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability, please **do not** open a public issue. Instead, please report it via one of the following methods:

### Preferred Method
1. Email: [Your security email] (if you have one)
2. GitHub Security Advisory: Use the "Report a vulnerability" button on the Security tab

### What to Include
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Time
- We will acknowledge receipt within 48 hours
- We will provide an initial assessment within 7 days
- We will keep you informed of our progress

## Security Best Practices

### Secrets Management
- All secrets are encrypted using SOPS with AGE keys
- Never commit unencrypted secrets
- Rotate secrets regularly (quarterly recommended)
- Store AGE keys securely (not in repository)

### Access Control
- Use SSH keys for Git operations
- Enable 2FA on all accounts
- Review access permissions regularly
- Use least-privilege principle

### Dependencies
- Keep dependencies up to date
- Review Renovate PRs carefully
- Use pinned versions for production
- Regularly audit dependencies for vulnerabilities

### Infrastructure
- Keep Kubernetes and Talos versions current
- Regularly update container images
- Monitor security advisories for all components
- Use network policies where applicable

## Security Updates

Security updates are handled through:
- **Renovate**: Automated dependency updates
- **Dependabot**: Security vulnerability alerts
- **GitHub Security Advisories**: For critical vulnerabilities

## Disclosure Policy

- Vulnerabilities will be disclosed after a fix is available
- We will credit security researchers who responsibly disclose vulnerabilities
- We follow responsible disclosure practices

## Security Checklist

Before deploying:
- [ ] All secrets are encrypted with SOPS
- [ ] Dependencies are up to date
- [ ] No hardcoded credentials
- [ ] Security scanning passed
- [ ] Access controls reviewed
- [ ] Backup and recovery tested

