# SSH Tunnels

## Part 1: Setup a Remote EC2 Instance

### 1.1: Create an SSH Key Pair
Creating a private-public key pair to access the remote ec2 instance using SSH.
```bash
KP_NAME="tutorial-key"

# Creating key pair to access the ec2 instance and save the private key.
aws ec2 create-key-pair \
--key-name $KP_NAME \
--key-type ed25519 \
--query "KeyMaterial" \
--output text > ~/.ssh/tutorial-key.pem

# Correct permissions required for SSH
chmod 400 ~/.ssh/tutorial-key.pem
```

### 1.2: Create a Security Group
Creating a security group for the ec2 instance to act as a firewall and blocking non-configured requests.

Allowing access to the port 22 from our current IP.
```bash
# Get Public IP for only allowing access to port 22 (SSH) from our CURRENT_IP.
CURRENT_IP=$(curl -s http://checkip.amazonaws.com)
SG_NAME="tutorial-security-group"

aws ec2 create-security-group \
--group-name $SG_NAME \
--description "Security Group For Temporary Remote EC2 Instance"

# Store Security Group ID for creating ingress rules.
SG_ID=$(aws ec2 describe-security-groups --group-names "$SG_NAME" --query "SecurityGroups[0].GroupId" --output text)

aws ec2 authorize-security-group-ingress \
--group-id $SG_ID \
--protocol tcp \
--port 22 \
--cidr "$CURRENT_IP/32"
```

### 1.3: Launch the EC2 Instance
The EC2 instance would be the `t2.micro` with the latest Ubuntu AMI.
```bash
AMI_ID=ami-087d1c9a513324697 # AMI For Ubuntu

aws ec2 run-instances \
--image-id $AMI_ID \
--count 1 \
--instance-type t2.micro \
--key-name $KP_NAME \
--security-group-ids $SG_ID
```

### 1.4: Get the IP and ID of the EC2 Instance
```bash
# Get the Instance ID of the instance we just launched.
INSTANCE_ID=$(aws ec2 describe-instances \
--query "Reservations[0].Instances[0].InstanceId" \
--output text)

echo "Instance ID: $INSTANCE_ID"

# Wait for the instance to get in the "running" state.
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Store its Public IP
EC2_IP=$(aws ec2 describe-instances \
--instance-ids $INSTANCE_ID \
--query "Reservations[0].Instances[0].PublicIpAddress" \
--output text)
```

## Part 2: Local Port Forwarding

**Scenario**: We want to run a PostgreSQL database on our EC2 instance. We need to connect to the
database using a client like `psql`, but we don't want to expose the database port (port 5432 on ec2)
to the public.

### 2.1: Running PostgreSQL on EC2 Instance
```bash
ssh -i ~/.ssh/tutorial-key.pem "ubuntu@$EC2_IP"

sudo apt upgrade
sudo snap install docker
sudo groupadd docker
sudo usermod -a -G docker $USER

# Only if necessary
sudo chown root:docker /var/run/docker.sock

# Verify running docker without sudo after rebuilding the connection to verify the change.
exit
ssh -i ~/.ssh/tutorial-key.pem "ubuntu@$EC2_IP"
docker ps # Should show output instead of permission error

# Run PostgreSQL Database on Port 5432 of EC2 Machine.
docker run --name postgres-db -d \
-p 5432:5432 \
-e POSTGRES_PASSWORD=admin123 \
postgres
```

### 2.2: Insecure Way of Connecting to DB (Don't Use This Method In Production)
To connect to the database running on port 5432 on the ec2 instance, we can
expose its 5432 port to the public by creating an outbound/egress rule to
prevent the firewall from blocking requests on the 5432 port.

This method allows anyone with your public IP access to the database
running on the ec2, which is **extremely unsecure**.

```bash
# Add a rule to allow your IP to access port 5432
aws ec2 authorize-security-group-ingress \
--group-id $SG_ID \
--protocol tcp \
--port 5432 \
--cidr "$CURRENT_IP/32"

# Now you can connect directly
psql "postgresql://postgres:admin123@$EC2_IP:5432/postgres"
```

### 2.3: The Secury Way using a Local SSH Tunnel
```bash
# Remove direct access to 5432 port on ec2 to prevent public access to the db.
aws ec2 revoke-security-group-ingress \
--group-id $SG_ID \
--protocol tcp \
--port 5432 \
--cidr "$CURRENT_IP/32"

# Verify direct access is not possible (should timeout)
psql "postgresql://postgres:admin123@$EC2_IP:5432/postgres"
```

Now we will create a **local port forward**. It will create a listener on the host machine
for the port 8080 (or any other specified port) and all data that arrives on this listener,
forward it to the SSH channel using the existing SSH connection and forward the data to the
**localhost:5432** of the ec2 machine.

So from the ec2 machine's perspective it is running PostgreSQL using Docker, which is essentially
listening for clients on localhost:5432, so any client who wants to connect to the PostgreSQL DB,
needs to connect to the localhost:5432 of the remote ec2 machine. Since we have a tunnel between
remote machine's 22 port and host machine's 22 port, we setup a listener on host machine say on
port 8080 and now the client connecting on host machine's localhost:8080 would effectively reach
remote ec2's 22 port and then sshd would forward the data from 22 port on remote machine to the
specified host+port i.e. localhost:5432, essentially creating a bidirectional communication as follows:

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'primaryColor':'#e8eaf6','primaryTextColor':'#1a237e','lineColor':'#5c6bc0'}}}%%

flowchart TD
    Start([Client Application]) -->|Sends request to| A[Port 8080]

    subgraph Host[HOST MACHINE]
        A -->|Forwards to| B[SSH Client - Port 22]
    end

    B ==>|Establishes| C[SSH Tunnel]

    subgraph Tunnel[ENCRYPTED SSH TUNNEL]
        C ==>|Connects to| D[SSH Server - Port 22]
    end

    subgraph Remote[REMOTE MACHINE]
        D -->|Routes to| E[PostgreSQL - Port 5432]
    end

    E -->|Response| End([Data Returned])

    style Start fill:#E8EAF6,stroke:#3F51B5,stroke-width:2px
    style A fill:#BBDEFB,stroke:#1976D2,stroke-width:2px
    style B fill:#90CAF9,stroke:#1565C0,stroke-width:2px
    style C fill:#FFF59D,stroke:#F57C00,stroke-width:3px
    style D fill:#FFAB91,stroke:#E64A19,stroke-width:2px
    style E fill:#A5D6A7,stroke:#388E3C,stroke-width:2px
    style End fill:#C8E6C9,stroke:#43A047,stroke-width:2px

    style Host fill:#F3F4F9,stroke:#5C6BC0,stroke-width:2px
    style Tunnel fill:#FFF8E1,stroke:#FF8F00,stroke-width:3px,stroke-dasharray: 5 5
    style Remote fill:#FAFAFA,stroke:#757575,stroke
```

```bash
ssh -N -f -L 8080:localhost:5432 -i ~/.ssh/tutorial-key.pem ubuntu@$EC2_IP
```

- `-N` Does not create an interactive session (doesn't provide the shell of the ec2).
- `-L 8080:localhost:5432` **L**ocal Forward. `[LOCAL_PORT]:[DESTINATION_HOST]:[DESTINATION_PORT]`
- `-f` backgrounds the ssh process, instead of hijacking the terminal.

Now attempt to connect to the PostgreSQL DB as if it were running on the host machine and listening on localhost:8080
```bash
psql postgresql://postgres:admin123@localhost:8080/postgres # BOOM! you can now access the db locally through the tunnel.
```

To close the tunnel just kill the process using
```bash
kill <pid-ssh-tunnel>
```

To find the pid of the ssh-tunnel
```bash
ps -ef | grep ssh
```

## Part 3: Remote Port Forwarding (NAT Bypass)

**Scenario**: You have a web app which you have developed locally on `localhost:3000`. You want to show it to a friend/expose it to the public,
but your device is behind a NAT or even a restrictive firewall. You can use your EC2 instance as a public middleman.

### 3.1: Run a Local Web Server

In your terminal start a simple web app:
```bash
mkdir local-web-server
echo "<h1>Yep it works!</h1>" > ./local-web-server/index.html
python3 -m http.server 3000 --directory local-web-server
```

### 3.2: Configure the EC2 firewall
For the public/friend to view you local web app, you need to expose a port on your ec2 instance,
that the friend can visit and get served the web app files.

```bash
# Allows all traffic from anywhere on the internet for your friend to access.
aws ec2 authorize-security-group-ingress \
--group-id $SG_ID \
--protocol tcp \
--port 5050 \
--cidr "0.0.0.0/0"
```

### 3.3: Create the Remote Tunnel

Connects to the EC2 Instance and tells it to listen on port 5050 for all network interfaces (0.0.0.0).
Now any traffic that arrives on the port 5050 through any network interface is going to be routed
to the localhost:3000 address of the host machine (your laptop).

```bash
ssh -N -f -R 0.0.0.0:5050:localhost:3000 -i ~/.ssh/tutorial-key.pem ubuntu@$EC2_IP
```

Now anyone including your friend can visit `http://<your-public-ec2-ip>:5050` which will direct them
to the web server running on your laptop at `localhost:3000` through your SSH tunnel as long as you don't
close the SSH process/tunnel.

> You can use this to bypass NAT and create your laptop a server. You can run a server on your laptop on the localhost
> and then create a tunnel from your laptop to a public facing ec2 instance. Now you just need to visit the public IP
> provided with your ec2 instance and then you can access your server on your local computer from anywhere on the world.
