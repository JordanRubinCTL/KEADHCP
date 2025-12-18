/*
########################################################################################################
####                                                                                                ####
####                            [DAS] Device Activation System                                      ####
####                                                                                                ####
#### KEA Server automation Demo                                                                     ####
#### Author : Jordan Rubin jordan.rubin@centurylink.com                                             ####
####                                                                                                ####
#### This is a demo to configure KEA DHCP server using Go.                                          ####
#### it builds out the subnets and reservations based on the provided workflow                      ####
#### This is just a POC and not fir production use.                                                 ####
########################################################################################################
####
#### 12/18/2025 - Initial Release
*/

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
)

const (
	keaAPIURL  = "http://100.87.19.138:8000"
	keaAPIUser = "kea-api"
	keaAPIPass = "keaapipassword"
	debug      = true
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

func main() {
	// Load workflow from file
	workflow, err := loadWorkflow("workflow.json")
	if err != nil {
		log.Fatalf("Error loading workflow: %v", err)
	}

	fmt.Println("EMULATED WORKFLOW FROM UPSTREAM")
	printJSON(workflow)

	subnetCount := len(workflow.Subnet)
	fmt.Printf("\nWill create %d new subnets from the workflow.\n", subnetCount)

	// Load template from file
	template, err := loadTemplate("template.json", workflow.Subnet)
	if err != nil {
		log.Fatalf("Error loading template: %v", err)
	}

	fmt.Println("\nTSG STENCIL FOR BUILD IN JSON")
	if debug {
		printJSON(template)
	}

	// API DEMO - List available commands
	if debug {
		fmt.Println("\nKEA DEMO APP\n\n\nKEA API COMMANDS AVAILABLE\n___________________________")
	}

	listCommandsPayload := map[string]interface{}{
		"command": "list-commands",
		"service": []string{"dhcp4"},
	}

	resp, err := sendToKea(listCommandsPayload)
	if err != nil {
		log.Fatalf("Error listing commands: %v", err)
	}

	if debug && len(resp) > 0 {
		if args, ok := resp[0].Arguments["arguments"].([]interface{}); ok {
			for _, cmd := range args {
				fmt.Printf("%v ,", cmd)
			}
		}
		fmt.Println("\n")
	}

	// BIGLOOP - Process each subnet
	for _, subnet := range workflow.Subnet {
		fmt.Printf("\nBUILD SUBNET [%s]--------------\n", subnet)

		// List all subnets in system
		listSubnetsPayload := map[string]interface{}{
			"command": "subnet4-list",
			"service": []string{"dhcp4"},
		}

		resp, err := sendToKea(listSubnetsPayload)
		if err != nil {
			log.Fatalf("Error listing subnets: %v", err)
		}

		if debug {
			printJSON(resp)
		}

		// Find first free subnet ID
		startSubnetID := findFreeSubnetID(resp)
		fmt.Printf("First free subnet id is %d\n", startSubnetID)

		// Parse subnet with CIDR
		_, ipnet, err := net.ParseCIDR(subnet)
		if err != nil {
			log.Fatalf("Error parsing subnet %s: %v", subnet, err)
		}

		// Calculate pool range
		first, last := getIPRange(ipnet)
		pool := fmt.Sprintf("%s-%s", first, last)
		masklen, _ := ipnet.Mask.Size()
		fmt.Printf("Full single pool for [%d] subnet as %s\n", masklen, pool)

		// Check for subnet overlap
		if checkSubnetOverlap(resp, subnet) {
			fmt.Printf("subnet overlap for %s\n", subnet)
			// continue or exit based on requirements
		}

		fmt.Printf("Building Subnet %s as index %d\n", subnet, startSubnetID)

		// Add subnet
		addSubnetPayload := map[string]interface{}{
			"command": "subnet4-add",
			"service": []string{"dhcp4"},
			"arguments": map[string]interface{}{
				"subnet4": []map[string]interface{}{
					{
						"id":                 startSubnetID,
						"subnet":             subnet,
						"max-valid-lifetime": 0,
						"min-valid-lifetime": 0,
						"valid-lifetime":     0,
						"pools": []map[string]interface{}{
							{
								"option-data": []interface{}{},
								"pool":        pool,
							},
						},
					},
				},
			},
		}

		if debug {
			printJSON(addSubnetPayload)
		}

		resp, err = sendToKea(addSubnetPayload)
		if err != nil {
			log.Printf("Error adding subnet: %v", err)
		}

		// Add host reservations for each matching port in template
		currentIP := net.ParseIP(first)
		for key := 1; key <= len(template); key++ {
			keyStr := strconv.Itoa(key)
			if port, exists := template[keyStr]; exists {
				if port.Subnet == subnet {
					flexID := fmt.Sprintf("'%s-%s'", workflow.Hostname, port.Port)
					myIP := currentIP.String()

					fmt.Printf("Adding host reservation for interface [%s]\n", keyStr)
					fmt.Printf("SUBNET:\t\t %s\n", port.Subnet)
					fmt.Printf("IP:\t\t %s\n", myIP)
					fmt.Printf("Relay:\t\t %s\n\n", workflow.Hostname)
					fmt.Printf("Flex-id: %s\n", flexID)

					// Add reservation
					addReservationPayload := map[string]interface{}{
						"command": "reservation-add",
						"service": []string{"dhcp4"},
						"arguments": map[string]interface{}{
							"reservation": map[string]interface{}{
								"subnet-id":  startSubnetID,
								"ip-address": myIP,
								"flex-id":    flexID,
								"hostname":   workflow.Hostname,
							},
						},
					}

					if debug {
						printJSON(addReservationPayload)
					}

					resp, err = sendToKea(addReservationPayload)
					if err != nil {
						log.Printf("Error adding reservation: %v", err)
					}
					printJSON(resp)
				}
			}
			currentIP = getNextIP(currentIP)
		}
	}

	// Write config to disk
	configWritePayload := map[string]interface{}{
		"command": "config-write",
		"service": []string{"dhcp4"},
	}

	resp, err = sendToKea(configWritePayload)
	if err != nil {
		log.Fatalf("Error writing config: %v", err)
	}

	printJSON(resp)
}

// loadWorkflow reads and parses the workflow JSON file
func loadWorkflow(filename string) (*Workflow, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return nil, err
	}

	var workflow Workflow
	err = json.Unmarshal(data, &workflow)
	if err != nil {
		return nil, err
	}

	return &workflow, nil
}

// loadTemplate reads and parses the template JSON file, replacing subnet placeholders
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
	err = json.Unmarshal([]byte(content), &template)
	if err != nil {
		return nil, err
	}

	return template, nil
}

// sendToKea sends a JSON payload to the Kea API
func sendToKea(payload interface{}) (KeaResponse, error) {
	jsonData, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequest("POST", keaAPIURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(keaAPIUser, keaAPIPass)

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var keaResp KeaResponse
	err = json.Unmarshal(body, &keaResp)
	if err != nil {
		return nil, err
	}

	return keaResp, nil
}

// findFreeSubnetID finds the first available subnet ID
func findFreeSubnetID(resp KeaResponse) int {
	if len(resp) == 0 {
		return 1
	}

	subnetList, ok := resp[0].Arguments["subnets"].([]interface{})
	if !ok {
		return 1
	}

	startSubnetID := 1
	for _, subnetInterface := range subnetList {
		subnetMap, ok := subnetInterface.(map[string]interface{})
		if !ok {
			continue
		}

		id, ok := subnetMap["id"].(float64)
		if !ok {
			continue
		}

		if int(id) == startSubnetID {
			fmt.Printf("Subnet ID %d in use\n", int(id))
			startSubnetID++
		} else {
			fmt.Printf("Subnet ID %d free\n", int(id))
			break
		}
	}

	return startSubnetID
}

// checkSubnetOverlap checks if subnet already exists
func checkSubnetOverlap(resp KeaResponse, subnet string) bool {
	if len(resp) == 0 {
		return false
	}

	subnetList, ok := resp[0].Arguments["subnets"].([]interface{})
	if !ok {
		return false
	}

	for _, subnetInterface := range subnetList {
		subnetMap, ok := subnetInterface.(map[string]interface{})
		if !ok {
			continue
		}

		existingSubnet, ok := subnetMap["subnet"].(string)
		if !ok {
			continue
		}

		if existingSubnet == subnet {
			return true
		}
	}

	return false
}

// getIPRange calculates the first and last usable IP in a subnet
func getIPRange(ipnet *net.IPNet) (string, string) {
	ip := ipnet.IP.To4()
	mask := ipnet.Mask

	// First IP
	firstIP := ip.Mask(mask)

	// Last IP (broadcast)
	lastIP := make(net.IP, 4)
	for i := range ip {
		lastIP[i] = ip[i] | ^mask[i]
	}

	return firstIP.String(), lastIP.String()
}

// getNextIP increments an IP address by 1
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

// printJSON pretty prints JSON data
func printJSON(data interface{}) {
	jsonBytes, err := json.MarshalIndent(data, "", "    ")
	if err != nil {
		log.Printf("Error marshaling JSON: %v", err)
		return
	}
	fmt.Println(string(jsonBytes))
}
