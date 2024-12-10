#!/bin/bash

# Function to check if a port is in use
check_port_usage() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 0    # Port is in use
    else
        return 1    # Port is available
    fi
}

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this script as root!"
    exit 1
fi

get_package_manager() {
    if [ -f /etc/debian_version ]; then
        echo "apt"
    elif [ -f /etc/redhat-release ]; then
        echo "yum"
    elif [ -f /etc/arch-release ]; then
        echo "pacman"
    else
        echo "unsupported"
    fi
}

install_iptables() {
    local pkg_manager=$(get_package_manager)

    case $pkg_manager in
        apt)
            apt update && apt install -y iptables iptables-persistent
            ;;
        yum)
            yum install -y iptables-services
            ;;
        pacman)
            pacman -Sy --noconfirm iptables
            ;;
        *)
            echo "Unsupported package manager. Please install iptables manually."
            exit 1
            ;;
    esac
    echo "iptables installed successfully."
}


get_ssh_port() {
    local ssh_port
    ssh_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
    echo "${ssh_port:-22}"
}

configure_firewall() {
    echo "Firewall Configuration:"
    echo "1. Enable Firewall (Allow only SSH port)"
    echo "2. Whitelist Custom Ports"
    echo "3. Back to main menu"
    read -p "Enter your choice: " FIREWALL_CHOICE

    case $FIREWALL_CHOICE in
        1)
            enable_firewall
            ;;
        2)
            whitelist_custom_ports
            ;;
        3)
            return
            ;;
        *)
            echo "Invalid choice. Please try again."
            ;;
    esac
}

# Function to enable the firewall
enable_firewall() {
    if ! command -v iptables &>/dev/null; then
        echo "iptables not found. Installing..."
        install_iptables
    fi

    local ssh_port
    ssh_port=$(get_ssh_port)
    echo "Detected SSH port: $ssh_port"

    # Configure iptables
    iptables -F
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT

    echo "Firewall enabled. Automatic enabled port SSH ($ssh_port)."
}


# Function to whitelist custom ports
whitelist_custom_ports() {
    read -p "Enter custom ports to whitelist (comma-separated, e.g., 25565,2255,213): " CUSTOM_PORTS
    if [[ -z "$CUSTOM_PORTS" ]]; then
        echo "No ports entered. Returning to firewall menu."
        return
    fi

    IFS=',' read -ra PORT_ARRAY <<< "$CUSTOM_PORTS"
    for PORT in "${PORT_ARRAY[@]}"; do
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$PORT" -ge 1 && "$PORT" -le 65535 ]]; then
            iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
            echo "Port $PORT has been whitelisted."
        else
            echo "Invalid port: $PORT. Skipping."
        fi
    done
}

# Function to create a new user
create_user() {
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

    # Ask if the user should be added to the sudo group
    read -p "Do you want to add $NEW_USER to the sudo group? [Y/n]: " ADD_SUDO
    ADD_SUDO=${ADD_SUDO:-Y} # Default to 'Y' if input is empty

    if [[ "$ADD_SUDO" =~ ^[Yy]$ ]]; then
        if getent group sudo &>/dev/null; then
            usermod -aG sudo "$NEW_USER"
            echo "User $NEW_USER has been added to the sudo group."
        else
            groupadd sudo
            usermod -aG sudo "$NEW_USER"
            echo "User $NEW_USER has been added to the newly created sudo group."
        fi
    else
        echo "User $NEW_USER will not be added to the sudo group."
    fi
}

# Function to enable key-based SSH login
enable_key_based_ssh() {
    echo "Enabling SSH login using key-based authentication only..."
    read -p "Have you already generated and distributed SSH keys? [Y/n]: " HAS_KEYS
    HAS_KEYS=${HAS_KEYS:-Y} # Default to 'Y'

    if [[ "$HAS_KEYS" =~ ^[Nn]$ ]]; then
        echo "Please generate SSH keys first using the 'Generate SSH Key' option."
        return
    fi

    # Update sshd_config to disable password authentication
    sed -i "s/^#PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
    systemctl restart sshd

    echo "SSH login has been configured to use key-based authentication only."
}

# Function to generate SSH key
generate_ssh_key() {
    echo "Generating SSH key pair..."
    read -p "Enter the username for SSH key generation: " SSH_USER
    if ! id "$SSH_USER" &>/dev/null; then
        echo "User $SSH_USER does not exist. Please create the user first."
        return
    fi

    KEY_FILE="id_rsa_$SSH_USER"
    ssh-keygen -t rsa -b 4096 -f "./$KEY_FILE" -N "" -q
    echo "SSH key pair generated: $KEY_FILE and $KEY_FILE.pub"

    # Ensure .ssh directory exists for the user
    USER_HOME=$(eval echo "~$SSH_USER")
    mkdir -p "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"

    # Add public key to authorized_keys
    cat "./$KEY_FILE.pub" >> "$USER_HOME/.ssh/authorized_keys"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
    chown -R "$SSH_USER:$SSH_USER" "$USER_HOME/.ssh"

    echo "SSH key for $SSH_USER has been generated and added to authorized_keys."
    echo "Private key file: $KEY_FILE"
    echo "You must distribute the private key securely to the user."
}



# Function to configure SSH
configure_ssh() {
    echo "SSH Configuration:"
    echo "1. Disable root login for SSH"
    echo "2. Change SSH port"
    echo "3. Enable SSH login only using key-based authentication"
    echo "4. Generate SSH Key"
    echo "5. Back to main menu"
    read -p "Enter your choice: " SSH_CHOICE
    case $SSH_CHOICE in
        1)
            disable_root_ssh
            ;;
        2)
            change_ssh_port
            ;;
        3)
            enable_key_based_ssh
            ;;
        4)
            generate_ssh_key
            ;;
        5)
            return
            ;;
        *)
            echo "Invalid choice. Please try again."
            ;;
    esac
}

# Function to disable root SSH login
disable_root_ssh() {
    if grep -q "^#PermitRootLogin " /etc/ssh/sshd_config; then
        sed -i "s/^#PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
    else
        sed -i "s/^PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
    fi
    systemctl restart sshd
    echo "Root login for SSH has been disabled."
}

# Function to change the SSH port
change_ssh_port() {
    read -p "Enter the new SSH port: " NEW_PORT
    if [[ "$NEW_PORT" -ge 1024 && "$NEW_PORT" -le 65535 ]]; then
        if check_port_usage "$NEW_PORT"; then
            echo "Port $NEW_PORT is already in use. Please choose another port."
            return
        else
            echo "SSH port is valid and available: $NEW_PORT"
        fi
    else
        echo "Invalid SSH port. Please enter a value between 1024 and 65535."
        return
    fi

    # Modify SSH port in the configuration file
    if grep -q "^#Port " /etc/ssh/sshd_config; then
        sed -i "s/^#Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
    else
        sed -i "s/^Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
    fi

    systemctl restart sshd
    echo "SSH port changed to $NEW_PORT."
}

install_fail2ban() {
    local pkg_manager=$(get_package_manager)

    case $pkg_manager in
        apt)
            apt update && apt install -y fail2ban
            ;;
        yum)
            yum install -y fail2ban
            ;;
        pacman)
            pacman -Sy --noconfirm fail2ban
            ;;
        *)
            echo "Unsupported package manager. Please install Fail2Ban manually."
            exit 1
            ;;
    esac

    systemctl enable fail2ban
    systemctl start fail2ban
    echo "Fail2Ban installed and started."
}


disable_unused_services() {
    echo "Listing all enabled services..."
    systemctl list-unit-files --type=service | grep enabled
    read -p "Enter the service to disable: " SERVICE_NAME
    systemctl disable "$SERVICE_NAME"
    echo "Service $SERVICE_NAME has been disabled."
}

install_lynis() {
    echo "Installing Lynis for security auditing..."
    local pkg_manager=$(get_package_manager)
    case $pkg_manager in
        apt)
            apt update && apt install -y lynis
            ;;
        yum)
            yum install -y lynis
            ;;
        pacman)
            pacman -Sy --noconfirm lynis
            ;;
        *)
            echo "Unsupported package manager. Please install Lynis manually."
            return
            ;;
    esac
    echo "Lynis installed. Running audit..."
    lynis audit system
}

# Main menu
while true; do
    echo "Main Menu:"
    echo "1. Create New User"
    echo "2. SSH Configuration"
    echo "3. Configure Firewall"
    echo "4. Install Fail2Ban"
    echo "5. Disable Unused Services"
    echo "6. Install Lynis for Security Audit"
    echo "7. Exit"
    read -p "Enter your choice: " MAIN_CHOICE

    case $MAIN_CHOICE in
        1)
            create_user
            ;;
        2)
            configure_ssh
            ;;
        3)
            configure_firewall
            ;;
        4)
            install_fail2ban
            ;;
        5)
            disable_unused_services
            ;;
        6)
            install_lynis
            ;;
        7)
            echo "Exiting script. Goodbye!"
            exit 0
            ;;
        *)
            echo "Invalid choice. Please try again."
            ;;
    esac
done
