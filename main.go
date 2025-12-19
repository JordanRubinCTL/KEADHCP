/*
########################################################################################################
####                                                                                                ####
####                            [DAS] Device Activation System                                      ####
####                                                                                                ####
#### KEA Server automation Demo - IMPROVED VERSION                                                  ####
#### Author : Jordan Rubin jordan.rubin@centurylink.com                                             ####
####                                                                                                ####
#### This is a demo to configure KEA DHCP server using Go.                                          ####
#### it builds out the subnets and reservations based on the provided workflow                      ####
#### This is just a POC and not for production use.                                                 ####
########################################################################################################
####
#### 5/1/2025 - Initial Release
#### 12/19/2025 - Improved version with proper error handling, validation, and bug fixes
*/

package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
)

// Configuration with environment variable support
var (
	keaAPIURL  = getEnv("KEA_API_URL", "http://100.87.19.138:8000")
	keaAPIUser = getEnv("KEA_API_USER", "kea-api")
	keaAPIPass = getEnv("KEA_API_PASS", "keaapipassword")
	debug      = getEnv("DEBUG", "true") == "true"
	mode       string // Will be set from command line flag
)

// Workflow represents the incoming workflow JSON structure
type Workflow struct {
	Hostname string   `json:"hostname"`
	Vendor   string   `json:"vendor"`
	Model    string   `json:"model"`
	Subnet   []string `json:"subnet"`
}

// TemplatePort represents a single port configuration in the template
type TemplatePort struct {
	Port   string `json:"port"`
	Subnet string `json:"subnet"`
	Type   string `json:"type"`
	Mask   int    `json:"mask"`
}

// KeaResponse represents the API response from Kea
type KeaResponse []struct {
	Result    int                    `json:"result"`
	Text      string                 `json:"text"`
	Arguments map[string]interface{} `json:"arguments,omitempty"`
}

// SubnetInfo represents subnet information from Kea
type SubnetInfo struct {
	ID     int    `json:"id"`
	Subnet string `json:"subnet"`
}

// APIResult represents the outcome of an API operation
type APIResult struct {
	Success bool
	Error   string
}

// Track created resources
var createdSubnets []int
var createdReservations []struct {
	SubnetID int
	IP       string
func main() {
	// Parse command line flags
	modeFlag := flag.String("mode", "test", "Execution mode: 'test' or 'real'")
	helpFlag := flag.Bool("help", false, "Display help message")
	flag.Parse()

	if *helpFlag {
		printUsage()
		os.Exit(0)
	}

	mode = *modeFlag
	if mode != "test" && mode != "real" {
		log.Fatalf("Invalid mode: %s. Must be 'test' or 'real'", mode)
	}

	// Display mode banner
	fmt.Println(strings.Repeat("=", 80))
	fmt.Printf("RUNNING IN %s MODE\n", strings.ToUpper(mode))
	fmt.Println(strings.Repeat("=", 80))
	if mode == "test" {
		fmt.Println("** TEST MODE: Will display API requests but NOT send them to Kea **")
	}
	else {
		fmt.Println("** REAL MODE: Will send actual API requests to Kea server **")
	}
	fmt.Println(strings.Repeat("=", 80))
	fmt.Println()

	// Wrapper for error handling
	if err := run(); err != nil {
		log.Fatalf("FATAL ERROR: %v", err)
	}
}	log.Fatalf("FATAL ERROR: %v", err)
	}
}

func run() error {
	// Load workflow from file
	workflow, err := loadWorkflow("workflow.json")
	if err != nil {
		return fmt.Errorf("error loading workflow: %w", err)
	}

	fmt.Println("EMULATED WORKFLOW FROM UPSTREAM")
	printJSON(workflow)

	subnetCount := len(workflow.Subnet)
	fmt.Printf("\nWill create %d new subnets from the workflow.\n", subnetCount)

	// Validate workflow has subnets
	if subnetCount == 0 {
		return fmt.Errorf("workflow contains no subnets")
	}

	// Load template from file
	template, err := loadTemplate("template.json", workflow.Subnet)
	if err != nil {
		return fmt.Errorf("error loading template: %w", err)
	}

	fmt.Println("\nTSG STENCIL FOR BUILD IN JSON")
	if debug {
		printJSON(template)
	}

	// API DEMO - List available commands
	if debug {
		fmt.Println("\nKEA DEMO APP\n\n\nKEA API COMMANDS AVAILABLE\n___________________________")
		commands, err := keaListCommands()
		if err != nil {
			log.Printf("Warning: Could not list commands: %v", err)
		}
		else {
			for _, cmd := range commands {
				fmt.Printf("%v ,", cmd)
			}
			fmt.Println("\n")
		}
	}

	// MAIN PROCESSING LOOP
	for _, subnet := range workflow.Subnet {
		fmt.Printf("\nBUILD SUBNET [%s]--------------\n", subnet)

		// Validate subnet format
		_, ipnet, err := net.ParseCIDR(subnet)
		if err != nil {
			log.Printf("ERROR: Invalid subnet format %s: %v - skipping", subnet, err)
			continue
		}

		// Get existing subnets
		existingSubnets, err := keaListSubnets()
		if err != nil {
			return fmt.Errorf("error listing subnets: %w", err)
		}

		// Find first free subnet ID (FIXED ALGORITHM)
		subnetID := findFreeSubnetID(existingSubnets)
		fmt.Printf("First free subnet id is %d\n", subnetID)

		// Calculate IP ranges
		ipInfo := calculateSubnetInfo(ipnet)

		// Check for subnet overlap
		if checkSubnetOverlap(existingSubnets, subnet) {
			log.Printf("WARNING: subnet overlap detected for %s - skipping", subnet)
			continue
		}

		// Add subnet to Kea
		fmt.Printf("Building Subnet %s with ID %d\n", subnet, subnetID)
		result := keaAddSubnet(subnetID, subnet, ipInfo)

		if !result.Success {
			return fmt.Errorf("failed to create subnet %s: %s", subnet, result.Error)
		}

		createdSubnets = append(createdSubnets, subnetID)
		fmt.Printf("Successfully created subnet %s\n", subnet)

		// Add host reservations for matching ports
		currentIP := net.ParseIP(ipInfo["first_ip"].(string))

		// Sort template keys for consistent processing
		var keys []int
		for k := range template {
			if num, err := strconv.Atoi(k); err == nil {
				keys = append(keys, num)
			}
		}
		sort.Ints(keys)

		for _, key := range keys {
			keyStr := strconv.Itoa(key)
			port := template[keyStr]

			// Only process if this port belongs to current subnet
			if port.Subnet == subnet {
				ipStr := currentIP.String()
				flexID := fmt.Sprintf("'%s-%s'", workflow.Hostname, port.Port)

				fmt.Printf("Adding host reservation for interface [%s]\n", keyStr)
				fmt.Printf("SUBNET:\t\t %s\n", port.Subnet)
				fmt.Printf("IP:\t\t %s\n", ipStr)
				fmt.Printf("Relay:\t\t %s\n", workflow.Hostname)
				fmt.Printf("Flex-id:\t %s\n\n", flexID)

				resResult := keaAddReservation(subnetID, ipStr, flexID, workflow.Hostname)

				if resResult.Success {
					createdReservations = append(createdReservations, struct {
						SubnetID int
						IP       string
					}{subnetID, ipStr})
					fmt.Printf("Successfully created reservation for %s\n", ipStr)
				}
				else {
					log.Printf("WARNING: Failed to create reservation for %s: %s", ipStr, resResult.Error)
				}
			}

			currentIP = getNextIP(currentIP)
		}
	}

	// Write configuration to disk
	fmt.Println("\nWriting configuration to disk...")
	writeResult := keaWriteConfig()

	if writeResult.Success {
		fmt.Println("Configuration successfully written!")
	}
	else {
		log.Printf("WARNING: Failed to write config: %s", writeResult.Error)
	}

	fmt.Println("\nProcessing complete!")
	fmt.Printf("Created %d subnets\n", len(createdSubnets))
	fmt.Printf("Created %d reservations\n", len(createdReservations))

	return nil
}

//###########################################################################################
// HELPER FUNCTIONS
//###########################################################################################

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func loadWorkflow(filename string) (*Workflow, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return nil, err
	}

	var workflow Workflow
	if err := json.Unmarshal(data, &workflow); err != nil {
		return nil, err
	}

	return &workflow, nil
}

func loadTemplate(filename string, subnets []string) (map[string]TemplatePort, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return nil, err
	}

	// Replace subnet placeholders
	content := string(data)
	for i, subnet := range subnets {
		placeholder := fmt.Sprintf("{{SUBNET_%d}}", i)
		content = strings.ReplaceAll(content, placeholder, subnet)
	}

	var template map[string]TemplatePort
	if err := json.Unmarshal([]byte(content), &template); err != nil {
		return nil, err
	}

	return template, nil
}

func calculateSubnetInfo(ipnet *net.IPNet) map[string]interface{} {
	ip := ipnet.IP.To4()
	mask := ipnet.Mask

	// First IP (network address)
	firstIP := ip.Mask(mask)

	// Last IP (broadcast)
	lastIP := make(net.IP, 4)
	for i := range ip {
		lastIP[i] = ip[i] | ^mask[i]
	}

	// First usable IP (network + 1)
	firstUsable := getNextIP(firstIP)

	pool := fmt.Sprintf("%s-%s", firstUsable.String(), lastIP.String())
	masklen, _ := ipnet.Mask.Size()

	fmt.Printf("Full single pool for [%d] subnet as %s\n", masklen, pool)

	return map[string]interface{}{
		"first_ip":     firstIP.String(),
		"last_ip":      lastIP.String(),
		"first_usable": firstUsable.String(),
		"pool":         pool,
		"masklen":      masklen,
	}
}

// FIXED: Proper algorithm to find free subnet ID
func findFreeSubnetID(subnetList []SubnetInfo) int {
	if len(subnetList) == 0 {
		return 1
	}

	// Extract and sort all existing IDs
	var existingIDs []int
	for _, subnet := range subnetList {
		existingIDs = append(existingIDs, subnet.ID)
	}
	sort.Ints(existingIDs)

	// Find first gap or return max+1
	nextID := 1
	for _, id := range existingIDs {
		if debug {
func sendToKea(payload interface{}) (KeaResponse, error) {
	jsonData, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal payload: %w", err)
	}

	if debug {
		fmt.Println("API REQUEST:")
		printJSON(payload)
	}

	// Determine if this is a read-only request
	var command string
	if payloadMap, ok := payload.(map[string]interface{}); ok {
		if cmd, ok := payloadMap["command"].(string); ok {
			command = cmd
		}
	}
	
	isReadOnly := strings.HasPrefix(command, "list-") || 
	              command == "subnet4-list" || 
	              command == "reservation-get" || 
	              command == "config-get" || 
	              command == "status-get" || 
	              command == "version-get"

	// TEST MODE: Only send read-only requests
	if mode == "test" && !isReadOnly {
		fmt.Println("[TEST MODE] Request prepared but NOT sent to Kea (write operation)")
		fmt.Println(strings.Repeat("-", 80))

		// Return a mock success response
		return KeaResponse{
			{
				Result: 0,
				Text:   "[TEST MODE] Simulated success",
				Arguments: map[string]interface{}{},
			},
		}, nil
	}

	if mode == "test" && isReadOnly {
		fmt.Println("[TEST MODE] Sending READ-ONLY request to Kea")
	}

	// REAL MODE or TEST MODE with read-only: Actually send the request
	req, err := http.NewRequest("POST", keaAPIURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(keaAPIUser, keaAPIPass)

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP request failed with status: %s", resp.Status)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
func keaListSubnets() ([]SubnetInfo, error) {
	payload := map[string]interface{}{
		"command": "subnet4-list",
		"service": []string{"dhcp4"},
	}

	// subnet4-list is read-only, so it will be sent even in test mode
	resp, err := sendToKea(payload)
	if err != nil {
		return nil, err
	}

	var subnetList []SubnetInfo

	if len(resp) > 0 {
		if subnets, ok := resp[0].Arguments["subnets"].([]interface{}); ok {
			for _, s := range subnets {
				if subnetMap, ok := s.(map[string]interface{}); ok {
					id, _ := subnetMap["id"].(float64)
					subnet, _ := subnetMap["subnet"].(string)
					subnetList = append(subnetList, SubnetInfo{
						ID:     int(id),
						Subnet: subnet,
					})
				}
			}
		}
	}

	return subnetList, nil
}
	var subnetList []SubnetInfo

	if len(resp) > 0 {
		if subnets, ok := resp[0].Arguments["subnets"].([]interface{}); ok {
			for _, s := range subnets {
				if subnetMap, ok := s.(map[string]interface{}); ok {
					id, _ := subnetMap["id"].(float64)
					subnet, _ := subnetMap["subnet"].(string)
					subnetList = append(subnetList, SubnetInfo{
						ID:     int(id),
						Subnet: subnet,
					})
				}
			}
		}
	}

	return subnetList, nil
}resp, err := sendToKea(payload)
	if err != nil {
		return nil, err
	}

	if len(resp) > 0 {
		if args, ok := resp[0].Arguments["arguments"].([]interface{}); ok {
			return args, nil
		}
	}

	return []interface{}{}, nil
}

func keaListSubnets() ([]SubnetInfo, error) {
	payload := map[string]interface{}{
		"command": "subnet4-list",
		"service": []string{"dhcp4"},
	}

	resp, err := sendToKea(payload)
	if err != nil {
		return nil, err
	}

	var subnetList []SubnetInfo

	if len(resp) > 0 {
		if subnets, ok := resp[0].Arguments["subnets"].([]interface{}); ok {
			for _, s := range subnets {
				if subnetMap, ok := s.(map[string]interface{}); ok {
					id, _ := subnetMap["id"].(float64)
					subnet, _ := subnetMap["subnet"].(string)
					subnetList = append(subnetList, SubnetInfo{
						ID:     int(id),
						Subnet: subnet,
					})
				}
			}
		}
	}

	return subnetList, nil
}

func keaAddSubnet(subnetID int, subnetCIDR string, ipInfo map[string]interface{}) APIResult {
	payload := map[string]interface{}{
		"command": "subnet4-add",
		"service": []string{"dhcp4"},
		"arguments": map[string]interface{}{
			"subnet4": []map[string]interface{}{
				{
					"id":                 subnetID,
					"subnet":             subnetCIDR,
					"max-valid-lifetime": 300,
					"min-valid-lifetime": 300,
					"valid-lifetime":     300,
					"pools": []map[string]interface{}{
						{
							"option-data": []interface{}{},
							"pool":        ipInfo["pool"],
						},
					},
					"option-data": []map[string]interface{}{
						{
							"name": "routers",
							"data": ipInfo["first_ip"],
						},
					},
				},
			},
		},
	}

	resp, err := sendToKea(payload)
	if err != nil {
		return APIResult{Success: false, Error: err.Error()}
	}

	if len(resp) > 0 {
		if resp[0].Result == 0 {
			return APIResult{Success: true}
		}
		return APIResult{Success: false, Error: resp[0].Text}
	}

	return APIResult{Success: false, Error: "No response from server"}
}

func keaAddReservation(subnetID int, ipAddress, flexID, hostname string) APIResult {
	payload := map[string]interface{}{
		"command": "reservation-add",
		"service": []string{"dhcp4"},
		"arguments": map[string]interface{}{
			"reservation": map[string]interface{}{
				"subnet-id":  subnetID,
				"ip-address": ipAddress,
				"flex-id":    flexID,
				"hostname":   hostname,
			},
		},
	}

	resp, err := sendToKea(payload)
	if err != nil {
		return APIResult{Success: false, Error: err.Error()}
	}

	if len(resp) > 0 {
		if resp[0].Result == 0 {
			return APIResult{Success: true}
		}
		return APIResult{Success: false, Error: resp[0].Text}
	}
	fmt.Println(string(jsonBytes))
}

func printUsage() {
	fmt.Println(`Usage: go run main_improved.go [OPTIONS]

OPTIONS:
    -mode=MODE     Set execution mode: 'test' or 'real' (default: test)
                   test - Display requests but don't send to Kea
                   real - Actually send requests to Kea server
    
    -help          Display this help message

ENVIRONMENT VARIABLES:
    KEA_API_URL    Kea API endpoint (default: http://100.87.19.138:8000)
    KEA_API_USER   API username (default: kea-api)
    KEA_API_PASS   API password (default: keaapipassword)
    DEBUG          Enable debug output (default: true)

EXAMPLES:
    # Test mode (dry run - no actual changes)
    go run main_improved.go -mode=test
    
    # Real mode (actually configure Kea)
    go run main_improved.go -mode=real
    
    # With custom credentials
    KEA_API_URL=http://server:8000 KEA_API_PASS=secret go run main_improved.go -mode=real
    
    # Build and run
    go build -o keadhcp main_improved.go
    ./keadhcp -mode=real
`)
}return APIResult{Success: false, Error: "No response from server"}
}

func keaWriteConfig() APIResult {
	payload := map[string]interface{}{
		"command": "config-write",
		"service": []string{"dhcp4"},
	}

	resp, err := sendToKea(payload)
	if err != nil {
		return APIResult{Success: false, Error: err.Error()}
	}

	if len(resp) > 0 {
		if resp[0].Result == 0 {
			return APIResult{Success: true}
		}
		return APIResult{Success: false, Error: resp[0].Text}
	}

	return APIResult{Success: false, Error: "No response from server"}
}

//###########################################################################################
// UTILITY FUNCTIONS
//###########################################################################################

func getNextIP(ip net.IP) net.IP {
	nextIP := make(net.IP, len(ip))
	copy(nextIP, ip)

	for i := len(nextIP) - 1; i >= 0; i-- {
		nextIP[i]++
		if nextIP[i] != 0 {
			break
		}
	}

	return nextIP
}

func printJSON(data interface{}) {
	jsonBytes, err := json.MarshalIndent(data, "", "    ")
	if err != nil {
		log.Printf("Error marshaling JSON: %v", err)
		return
	}
	fmt.Println(string(jsonBytes))
}
