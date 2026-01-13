# 🐉 Dragon Forge

Private custom builds for mobile graphics acceleration.

## Variants

| Variant | Code | Description |
|---------|------|-------------|
| Tiger | `tiger` | Base stable with velocity |
| Tiger-Phoenix | `tiger-phoenix` | Tiger + enhanced wings |
| Falcon | `falcon` | Legacy device support |
| Shadow | `shadow` | Experimental features |
| Hawk | `hawk` | Maximum power |

## Usage

### GitHub Actions
1. Go to **Actions** tab
2. Select **Dragon Forge**
3. Click **Run workflow**
4. Choose variant

### Local Build
```bash
# Single variant
./scripts/forge.sh tiger

# All variants
./scripts/forge.sh all

# Custom commit
./scripts/forge.sh tiger abc123f
