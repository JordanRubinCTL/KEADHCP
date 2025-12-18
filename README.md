# Kea DHCP Configuration Tool

This Go program configures a Kea DHCP server via its REST API. It's a port of the original Perl implementation.

## Features

- Configures Kea DHCP server using REST API
- Creates subnets and host reservations automatically
- Separate JSON configuration files for workflow and templates
- Automatic subnet ID management to avoid conflicts

## Files

- `main.go` - Main Go program
- `workflow.json` - Workflow configuration (hostname, vendor, model, subnets)
- `template.json` - Port/interface template configuration
- `go.mod` - Go module definition

## Configuration

### workflow.json
Contains the device information and subnets to configure:
```json
{
    "hostname": "LAB3COZSYJ001",
    "vendor": "Cisco",
    "model": "NCS540",
    "subnet": ["192.168.1.0/30", "192.168.1.4/30", "10.237.81.136/29"]
}
```

### template.json
Defines the port configurations with subnet placeholders (`{{SUBNET_0}}`, `{{SUBNET_1}}`, etc.):
```json
{
    "1": {
        "port": "gi1/1",
        "subnet": "{{SUBNET_0}}",
        "type": "mgmt",
        "mask": 30
    }
}
```

## API Configuration

Update these constants in `main.go` to match your Kea API server:
```go
const (
    keaAPIURL  = "http://100.87.19.138:8000"
    keaAPIUser = "kea-api"
    keaAPIPass = "keaapipa55w0rd"
    debug      = true
)
```

## Usage

1. Edit `workflow.json` with your device and subnet information
2. Edit `template.json` with your port configurations
3. Run the program:
   ```bash
   go run main.go
   ```

## Building

To build a standalone executable:
```bash
go build -o keadhcp
./keadhcp
```

## How It Works

1. Loads workflow configuration from `workflow.json`
2. Loads template configuration from `template.json` and replaces subnet placeholders
3. Connects to Kea DHCP API
4. For each subnet in the workflow:
   - Lists existing subnets and finds next available subnet ID
   - Creates the subnet with appropriate pool ranges
   - Adds host reservations for each matching port in the template
5. Writes the configuration to disk on the Kea server

## Original Author

Jordan Rubin (jordan.rubin@centurylink.com)

Ported from Perl to Go - December 2025
