#!/bin/bash

# Function to check if a port is in use
check_port_usage() {
	local port=$1
	if ss -tuln | grep -q ":$port "; then
		return 0	# Port is in use
	else
		return 1	# Port is available
	fi
}

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
	echo "Please run this script as root!"
	exit 1
fi

# Prompt to create a new user for SSH
read -p "Do you want to create a new user for SSH? [Y/n]: " CREATE_USER
CREATE_USER=${CREATE_USER:-Y} # Default to Y if empty

if [[ "$CREATE_USER" =~ ^[Yy]$ ]]; then
    read -p "Enter the new username: " NEW_USER

    # Prompt for password and confirm password
    while true; do
        read -s -p "Enter the password for the new user: " NEW_PASSWORD
        echo
        read -s -p "Confirm the password: " CONFIRM_PASSWORD
        echo

        if [[ "$NEW_PASSWORD" == "$CONFIRM_PASSWORD" ]]; then
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done

    # Create a new user
    if id "$NEW_USER" &>/dev/null; then
        echo "User $NEW_USER already exists."
    else
        useradd -m -s /bin/bash "$NEW_USER"
        echo "$NEW_USER:$NEW_PASSWORD" | chpasswd
        echo "User $NEW_USER has been created."
    fi

    # Add the user to the sudo/admin group
    if getent group sudo &>/dev/null; then
        usermod -aG sudo "$NEW_USER"
        echo "User $NEW_USER has been added to the sudo group."
    else
        if ! getent group admin &>/dev/null; then
            groupadd admin
            echo "%admin ALL=(ALL) ALL" >> /etc/sudoers
            echo "Admin group created and added to sudoers."
        fi
        usermod -aG admin "$NEW_USER"
        echo "User $NEW_USER has been added to the admin group."
    fi
else
    echo "Skipping new user creation."
fi

# Prompt to disable root SSH access
read -p "Do you want to disable root login for SSH? [Y/n]: " DISABLE_ROOT_SSH
DISABLE_ROOT_SSH=${DISABLE_ROOT_SSH:-Y} # Default to Y if empty

if [[ "$DISABLE_ROOT_SSH" =~ ^[Yy]$ ]]; then
    if grep -q "^#PermitRootLogin " /etc/ssh/sshd_config; then
        sed -i "s/^#PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
    else
        sed -i "s/^PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
    fi
    echo "Root login for SSH has been disabled."
else
    echo "Root login for SSH remains enabled."
fi

# Prompt to change SSH port
read -p "Do you want to change the SSH port? [Y/n]: " CHANGE_SSH_PORT
CHANGE_SSH_PORT=${CHANGE_SSH_PORT:-Y} # Default to Y if empty

if [[ "$CHANGE_SSH_PORT" =~ ^[Yy]$ ]]; then
    read -p "Enter the new SSH port: " NEW_PORT
    if [[ "$NEW_PORT" -ge 1024 && "$NEW_PORT" -le 65535 ]]; then
        if check_port_usage "$NEW_PORT"; then
            echo "Port $NEW_PORT is already in use. Please choose another port."
            exit 1
        else
            echo "SSH port is valid and available: $NEW_PORT"
        fi
    else
        echo "Invalid SSH port. Please enter a value between 1024 and 65535."
        exit 1
    fi

    # Modify SSH port in the configuration file
    if grep -q "^#Port " /etc/ssh/sshd_config; then
        sed -i "s/^#Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
    else
        sed -i "s/^Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
    fi

    echo "SSH port changed to $NEW_PORT."
else
    NEW_PORT=22 # Default to port 22 if not changing
    echo "SSH port change skipped. Using default port 22."
fi

# Check if iptables is installed
if ! command -v iptables &>/dev/null; then
	echo "iptables not found. Installing..."
	if [[ -f /etc/debian_version ]]; then
		apt update && apt install -y iptables iptables-persistent
	elif [[ -f /etc/redhat-release ]]; then
		yum install -y iptables iptables-services
	else
		echo "Unsupported distribution. Please install iptables manually."
		exit 1
	fi
	echo "iptables has been successfully installed."
else
	echo "iptables is already installed."
fi

# Ask if the user wants to enable a firewall with iptables
read -p "Do you want to enable firewall rules using iptables? [Y/n]: " USE_FIREWALL
USE_FIREWALL=${USE_FIREWALL:-Y}	# Default to Y if empty

if [[ "$USE_FIREWALL" =~ ^[Yy]$ ]]; then
	# Prompt for custom port whitelisting
	
	read -p "Do you want to whitelist additional ports? [Y/n]: " CONFIRM
	CONFIRM=${CONFIRM:-Y}	# Default to Y if empty

	if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
		echo "Enter additional ports to whitelist."
		read -p "Enter additional ports (comma-separated, e.g., 25565,25567): " CUSTOM_PORTS

		if [[ -z "$CUSTOM_PORTS" ]]; then
			echo "No additional ports were entered."
		else
			echo "Ports to be whitelisted: $CUSTOM_PORTS"
		fi
	fi

	# Configure iptables to block all ports except whitelisted ones
	echo "Setting iptables rules to block all ports except whitelisted ones..."
	iptables -F	# Clear old rules
	iptables -P INPUT DROP	# Set default INPUT policy to DROP
	iptables -P FORWARD DROP	# Set default FORWARD policy to DROP
	iptables -P OUTPUT ACCEPT	# Set default OUTPUT policy to ACCEPT
	# Allow traffic on localhost
	iptables -A INPUT -i lo -j ACCEPT
	iptables -A INPUT -i lo -j LOG --log-prefix "LOOPBACK TRAFFIC BLOCKED: " --log-level 4
	# Allow traffic for established connections
	iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j LOG --log-prefix "ESTABLISHED/RELATED BLOCKED: " --log-level 4
	# Allow the new SSH port
	iptables -A INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT
	iptables -A INPUT -p tcp --dport "$NEW_PORT" -j LOG --log-prefix "SSH TRAFFIC BLOCKED: " --log-level 4
	echo "Port $NEW_PORT allowed for SSH."

	# Allow custom ports if any
	if [[ "$CONFIRM" =~ ^[Yy]$ && -n "$CUSTOM_PORTS" ]]; then
		IFS=',' read -ra PORT_ARRAY <<< "$CUSTOM_PORTS"
		for PORT in "${PORT_ARRAY[@]}"; do
			iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
			iptables -A INPUT -p tcp --dport "$PORT" -j LOG --log-prefix "CUSTOM PORT BLOCKED: " --log-level 4
			echo "Port $PORT allowed."
		done
	fi

	read -p "Do you want to whitelist all Indonesian IPs? [Y/n]: " CONFIRM_IPS
	CONFIRM_IPS=${CONFIRM_IPS:-Y} # Default to Y if empty

	if [[ "$CONFIRM_IPS" =~ ^[Yy]$ ]]; then
		echo "Whitelisting..."
		INFO_CONFIRMS_IPS="Yes"
		
		# URL lokasi file subnet
		DATA_URL="https://raw.githubusercontent.com/Mightinity/secureme/refs/heads/main/Subnets/indonesian_subnet.txt"

		# Mengecek apakah curl atau wget tersedia
		if command -v curl &> /dev/null; then
			DATA=$(curl -s "$DATA_URL")
		elif command -v wget &> /dev/null; then
			DATA=$(wget -qO- "$DATA_URL")
		else
			echo "Neither curl nor wget is installed. Please install one to continue."
			exit 1
		fi

		# Jika DATA kosong, gagal mengambil file
		if [[ -z "$DATA" ]]; then
			echo "Failed to retrieve data from $DATA_URL. Please check your internet connection or URL."
			exit 1
		fi

		# Membaca setiap subnet dari data yang diunduh
		echo "$DATA" | while IFS= read -r subnet; do
			if [[ -n "$subnet" ]]; then
				iptables -A INPUT -s "$subnet" -j ACCEPT
				iptables -A INPUT -s "$subnet" -j LOG --log-prefix "WHITELISTED SUBNET BLOCKED: " --log-level 4
				# echo "Whitelisted subnet: $subnet"
			fi
		done
	else
		INFO_CONFIRMS_IPS="No"
	fi

	# Log all other traffic before dropping
	iptables -A INPUT -j LOG --log-prefix "TRAFFIC DROPPED: " --log-level 4
	iptables -A INPUT -j DROP

	# Save iptables rules
	if [[ ! -d /etc/iptables ]]; then
		mkdir -p /etc/iptables
	fi
	iptables-save > /etc/iptables/rules.v4
	echo "iptables rules have been saved."
else
	echo "Firewall rules not applied."
fi

# Restart SSH service
systemctl restart sshd
echo "SSH service restarted."

# Display configuration summary
echo "Configuration completed!"
echo "SSH Port: $NEW_PORT"
if [[ "$USE_FIREWALL" =~ ^[Yy]$ ]]; then
	if [[ "$CONFIRM" =~ ^[Yy]$ && -n "$CUSTOM_PORTS" ]]; then
		echo "Whitelisted ports: $CUSTOM_PORTS"
	else
		echo "No additional ports were whitelisted."
	fi
fi
echo "New user: $NEW_USER (with sudo/admin privileges)"
echo "Whitelist Indonesian's Subnet IPs: $INFO_CONFIRMS_IPS"
