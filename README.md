# Kea DHCP Configuration Tool

This project provides automated configuration of Kea DHCP servers via the REST API. Available in both Perl and Go implementations with identical functionality.

## Features

- 🔧 Automated subnet creation and management
- 🎯 Host reservation configuration with flex-id support
- 🔍 Intelligent subnet ID allocation (finds gaps in existing IDs)
- ✅ Proper error handling and validation
- 🧪 **Test mode** - Dry run with read-only operations
- 🚀 **Real mode** - Apply actual configuration changes
- 📊 External JSON configuration files for workflow and templates
- 🔒 Environment variable support for credentials
- 📝 Comprehensive logging and progress tracking

## Files

### Core Programs
- `dhcptest.pl` - Perl implementation
- `main.go` - Go implementation
- `go.mod` - Go module definition

### Configuration Files
- `workflow.json` - Device information and subnets to configure
- `template.json` - Port/interface template configuration

### Documentation
- `README.md` - This file
- `IMPROVEMENTS.md` - Detailed list of improvements and fixes
- `TEST_REAL_MODE.md` - Guide to test vs real mode usage

---

## Quick Start

### Perl Version

```bash
# Test mode (safe - shows what would happen)
perl dhcptest.pl --mode=test

# Real mode (actually configures Kea)
perl dhcptest.pl --mode=real

# With custom credentials
KEA_API_URL=http://192.168.1.100:8000 \
KEA_API_PASS=mypassword \
perl dhcptest.pl --mode=real

# Help
perl dhcptest.pl --help
```

### Go Version

```bash
# Test mode (safe - shows what would happen)
go run main.go -mode=test

# Real mode (actually configures Kea)
go run main.go -mode=real

# With custom credentials
KEA_API_URL=http://192.168.1.100:8000 \
KEA_API_PASS=mypassword \
go run main.go -mode=real

# Build and run
go build -o keadhcp main.go
./keadhcp -mode=test
./keadhcp -mode=real

# Help
go run main.go -help
```

---

## Configuration

### workflow.json
Defines the device and subnets to configure:
```json
{
    "hostname": "LAB3COZSYJ001",
    "vendor": "Cisco",
    "model": "NCS540",
    "subnet": [
        "192.168.1.0/30",
        "192.168.1.4/30",
        "10.237.81.136/29"
    ]
}
```

### template.json
Defines port configurations with subnet placeholders:
```json
{
    "1": {
        "port": "gi1/1",
        "subnet": "{{SUBNET_0}}",
        "type": "mgmt",
        "mask": 30
    },
    "2": {
        "port": "gi1/2",
        "subnet": "{{SUBNET_1}}",
        "type": "mgmt",
        "mask": 30
    }
}
```

Placeholders `{{SUBNET_0}}`, `{{SUBNET_1}}`, etc. are automatically replaced with values from the workflow.

### Environment Variables

```bash
export KEA_API_URL="http://100.87.19.138:8000"  # Kea API endpoint
export KEA_API_USER="kea-api"                   # API username
export KEA_API_PASS="keaapipassword"            # API password
export DEBUG="1"                                # Enable debug output (1 or 0)
```

---

## Test Mode vs Real Mode

### Test Mode (Default - Safe)
- ✅ **Sends read-only requests** to Kea (list-commands, subnet4-list)
- ✅ Shows what subnets already exist
- ✅ Displays all configuration that would be created
- ✅ Validates JSON payloads
- ❌ **Does NOT send write requests** (subnet4-add, reservation-add, config-write)
- Returns simulated success for write operations

**Perfect for:**
- Verifying workflow and template configuration
- Checking against real Kea server state
- Validating subnet calculations
- Dry-run before making changes

### Real Mode (Production)
- Sends ALL API requests including writes
- Actually creates subnets and reservations
- Writes configuration to Kea server disk

**Use when:**
- Ready to apply actual configuration changes
- After testing in test mode

---

## How It Works

1. **Loads Configuration**
   - Reads `workflow.json` for device and subnet information
   - Reads `template.json` and replaces subnet placeholders

2. **Connects to Kea API**
   - Lists available commands
   - Retrieves existing subnets

3. **For Each Subnet:**
   - Finds next available subnet ID (handles gaps in existing IDs)
   - Calculates IP ranges and pool
   - Checks for overlaps with existing subnets
   - Creates subnet with appropriate settings:
     - Valid lifetime: 300 seconds
     - Pool range: first usable IP to last IP
     - Default gateway (routers option)

4. **For Each Port in Template:**
   - Creates host reservation if port matches subnet
   - Uses flex-id for reservation identification
   - Assigns sequential IPs starting from network address

5. **Writes Configuration**
   - Saves configuration to disk on Kea server

---

## Key Improvements

This version includes significant improvements over the original:

### Critical Bug Fixes
- ✅ **Fixed subnet ID discovery algorithm** - Now correctly finds gaps
- ✅ **Proper JSON encoding** - Safe from injection vulnerabilities
- ✅ **Comprehensive error handling** - All API calls validated
- ✅ **Subnet overlap detection** - Actually prevents duplicates

### Enhanced Features
- ✅ **Test/Real mode** with read-only request support
- ✅ **Environment variable configuration**
- ✅ **Input validation** (subnet format, bounds checking)
- ✅ **Resource tracking** (counts created subnets/reservations)
- ✅ **Modular code organization**
- ✅ **HTTP status checking**
- ✅ **Success/failure results** for each operation

See `IMPROVEMENTS.md` for complete details.

---

## Example Output

### Test Mode
```
================================================================================
RUNNING IN TEST MODE
================================================================================
** TEST MODE: Will display API requests but NOT send them to Kea **
================================================================================

EMULATED WORKFLOW FROM UPSTREAM
Will create 3 new subnets from the workflow.

[TEST MODE] Sending READ-ONLY request to Kea
Existing subnets: 192.168.1.0/30, 10.0.0.0/8
First free subnet id is 3

BUILD SUBNET [192.168.1.4/30]--------------
Full single pool for [30] subnet as 192.168.1.5-192.168.1.7

[TEST MODE] Request prepared but NOT sent to Kea (write operation)
Would create subnet 192.168.1.4/30...
```

### Real Mode
```
================================================================================
RUNNING IN REAL MODE
================================================================================
** REAL MODE: Will send actual API requests to Kea server **
================================================================================

BUILD SUBNET [192.168.1.4/30]--------------
Successfully created subnet 192.168.1.4/30
Adding host reservation for interface [1]
Successfully created reservation for 192.168.1.4

Writing configuration to disk...
Configuration successfully written!

Processing complete!
Created 3 subnets
Created 4 reservations
```

---

## Requirements

### Perl
- Perl 5.10 or higher
- Required modules:
  - `LWP::UserAgent`
  - `JSON`
  - `HTTP::Request::Common`
  - `NetAddr::IP`
  - `Getopt::Long` (core module)

```bash
# Install dependencies
cpan LWP::UserAgent JSON HTTP::Request::Common NetAddr::IP
```

### Go
- Go 1.21 or higher
- No external dependencies (uses standard library only)

---

## Kea API Configuration

Ensure your Kea DHCP server has the control-agent configured:

```json
{
    "Control-agent": {
        "http-host": "0.0.0.0",
        "http-port": 8000,
        "authentication": {
            "type": "basic",
            "realm": "kea-control-agent",
            "clients": [{
                "user": "kea-api",
                "password": "keaapipassword"
            }]
        },
        "control-sockets": {
            "dhcp4": {
                "socket-type": "unix",
                "socket-name": "/tmp/kea4-ctrl-socket"
            }
        }
    }
}
```

---

## Troubleshooting

### Connection Errors
```bash
# Verify Kea API is accessible
curl -u kea-api:password http://100.87.19.138:8000 \
  -H "Content-Type: application/json" \
  -d '{"command":"list-commands","service":["dhcp4"]}'
```

### Subnet ID Conflicts
The script automatically finds free subnet IDs, including gaps. Run in test mode first to verify.

### Invalid Subnet Format
Ensure subnets in `workflow.json` use CIDR notation: `192.168.1.0/30`

### Permission Errors
Verify API credentials in environment variables or use defaults matching your Kea configuration.

---

## Development

### Testing
Always run in test mode first:
```bash
perl dhcptest.pl --mode=test
go run main.go -mode=test
```

### Adding New Features
Both implementations maintain feature parity. Update both when adding functionality.

### Code Structure
- `main` / `sub main` - Main orchestration
- `send_to_kea` / `sendToKea` - API communication with mode detection
- `kea_*` functions - Specific API operations
- Helper functions - Subnet calculation, validation, etc.

---

## Author

**Jordan Rubin**  
Email: jordan.rubin@centurylink.com

## Version History

- **5/1/2025** - Initial Release
- **12/19/2025** - Major improvements:
  - Added error handling and validation
  - Implemented test/real mode with read-only support
  - Fixed subnet ID discovery algorithm
  - Added proper JSON encoding
  - External configuration files
  - Environment variable support

## License

This is a POC (Proof of Concept) and not for production use without further testing and validation.

---

## See Also

- `IMPROVEMENTS.md` - Detailed changelog and improvements
- `TEST_REAL_MODE.md` - Complete guide to test vs real mode
- [Kea Documentation](https://kea.readthedocs.io/)
- [Kea API Reference](https://kea.readthedocs.io/en/latest/api.html)
