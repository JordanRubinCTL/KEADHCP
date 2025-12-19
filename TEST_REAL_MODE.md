# Test vs Real Mode - Quick Reference

Both improved scripts now support `--mode` (Perl) or `-mode` (Go) command-line parameter.

## Modes

### **TEST Mode (Default - Safe)**
- Displays all API requests that would be sent
- **Sends READ-ONLY requests** to Kea server (list-commands, subnet4-list, etc.)
- **Does NOT send WRITE requests** (subnet4-add, reservation-add, config-write)
- Returns simulated success responses for write operations
- Perfect for:
  - Verifying workflow and template are correct
  - Checking subnet calculations against actual Kea data
  - Validating JSON payload structure
  - Seeing what subnets already exist
  - Dry-run before making real changes

### **REAL Mode (Production)**
- Actually sends ALL API requests to Kea server
- Makes real configuration changes
- Use only when ready to apply changes

---

## Read-Only Commands (Sent in Both Modes)

These commands are safe and will be sent to Kea even in TEST mode:
- `list-commands` - List available API commands
- `subnet4-list` - List existing subnets
- `reservation-get` - Get reservation details
- `config-get` - Get configuration
- `status-get` - Get server status
- `version-get` - Get Kea version

## Write Commands (Only Sent in REAL Mode)

These commands modify Kea configuration and are simulated in TEST mode:
- `subnet4-add` - Add new subnet
- `reservation-add` - Add host reservation
- `config-write` - Write config to disk
- `subnet4-del` - Delete subnet
- `reservation-del` - Delete reservation

---

## Usage Examples

### Perl Version

```bash
# TEST mode (dry run) - DEFAULT
perl dhcptest_improved.pl
perl dhcptest_improved.pl --mode=test

# REAL mode (actually configure Kea)
perl dhcptest_improved.pl --mode=real

# With custom credentials
KEA_API_URL=http://192.168.1.100:8000 \
KEA_API_PASS=mypassword \
perl dhcptest_improved.pl --mode=real

# Show help
perl dhcptest_improved.pl --help
```

### Go Version

```bash
# TEST mode (dry run) - DEFAULT
go run main_improved.go
go run main_improved.go -mode=test

# REAL mode (actually configure Kea)
go run main_improved.go -mode=real

# With custom credentials
KEA_API_URL=http://192.168.1.100:8000 \
KEA_API_PASS=mypassword \
go run main_improved.go -mode=real

# Build first, then run
go build -o keadhcp main_improved.go
./keadhcp -mode=test
./keadhcp -mode=real

# Show help
go run main_improved.go -help
```

---

## What You'll See

### In TEST Mode:
```
================================================================================
RUNNING IN TEST MODE
================================================================================
** TEST MODE: Will display API requests but NOT send them to Kea **
================================================================================

EMULATED WORKFLOW FROM UPSTREAM
...

API REQUEST:
{
    "command": "subnet4-add",
    "service": ["dhcp4"],
    ...
}
[TEST MODE] Request prepared but NOT sent to Kea
--------------------------------------------------------------------------------
```

### In REAL Mode:
```
================================================================================
RUNNING IN REAL MODE
================================================================================
** REAL MODE: Will send actual API requests to Kea server **
================================================================================

EMULATED WORKFLOW FROM UPSTREAM
...

API REQUEST:
{
    "command": "subnet4-add",
    ...
}
API RESPONSE:
[
    {
        "result": 0,
        "text": "IPv4 subnet 192.168.1.0/30 added"
    }
]
Successfully created subnet 192.168.1.0/30
```

---

## Recommended Workflow

1. **Always test first:**
   ```bash
   perl dhcptest_improved.pl --mode=test
   ```

2. **Review the output carefully:**
   - Check subnet calculations
   - Verify IP addresses are correct
   - Ensure pool ranges are valid
   - Validate reservation assignments

3. **When satisfied, run in REAL mode:**
   ```bash
   perl dhcptest_improved.pl --mode=real
   ```

4. **Verify on Kea server:**
   ```bash
   # Check Kea configuration
   curl -u kea-api:password http://server:8000 \
     -H "Content-Type: application/json" \
     -d '{"command":"subnet4-list","service":["dhcp4"]}'
   ```

---

## Environment Variables (Optional)

```bash
export KEA_API_URL="http://192.168.1.100:8000"
export KEA_API_USER="admin"
export KEA_API_PASS="supersecret"
export DEBUG="1"

# Now run without specifying credentials each time
perl dhcptest_improved.pl --mode=real
go run main_improved.go -mode=real
```

---

## Error Handling

The scripts will:
- ✅ Validate mode parameter (must be 'test' or 'real')
- ✅ Skip invalid subnets with warnings
- ✅ Check for subnet overlaps
- ✅ Report API errors in REAL mode
- ✅ Track successfully created resources

---

## Safety Features

1. **Test mode is the default** - must explicitly specify `--mode=real`
2. **Mode is displayed prominently** at the start
3. **Subnet overlap detection** prevents duplicates
4. **Input validation** catches format errors
5. **Error messages** clearly indicate what went wrong
