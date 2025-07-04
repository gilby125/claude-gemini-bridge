# Security Guidelines

## API Key Management

### ⚠️ IMPORTANT: Never commit API keys to git!

The `hooks/config/debug.conf` file contains sensitive information including API keys and should never be committed to version control.

### Setup Process

1. **Template**: The repository includes `hooks/config/debug.conf.template` as a safe template
2. **Installation**: The installer automatically copies the template to `debug.conf`
3. **Configuration**: Edit `debug.conf` locally to add your API keys
4. **Git Protection**: The `.gitignore` prevents `debug.conf` from being committed

### If You Accidentally Commit an API Key

1. **Immediately revoke the exposed API key** in your provider's dashboard
2. **Generate a new API key**
3. **Update your local `debug.conf` with the new key**
4. **Consider using git history rewriting tools** if the key was recently committed

### Best Practices

- Never share your `debug.conf` file
- Use environment variables for CI/CD pipelines
- Regularly rotate API keys
- Use API key restrictions when available (IP restrictions, scope limitations)

### File Permissions

Set restrictive permissions on the config file:
```bash
chmod 600 hooks/config/debug.conf
```

## Supported Providers

### OpenRouter
- Get API keys at: https://openrouter.ai/
- Free tier available with `openrouter/cypher-alpha:free`
- API key format: `sk-or-v1-...`

### Google Gemini
- Uses local CLI authentication
- No API key needed in config file
- Set up via: `gemini auth login`