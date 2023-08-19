#!/bin/bash
#
# Docker host secure configuration checks

DOCKER_ENGINE_MAJOR_VERSION=20
DOCKER_COMPOSE_VERSION=1.12.0

# Check if Docker is installed
which docker >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    # Check Docker client version
    DOCKER_CLIENT_VERSION=$(docker version --format '{{.Client.Version}}')
    DOCKER_CLIENT_MAJOR_VERSION=$(echo $DOCKER_CLIENT_VERSION | cut -f1 -d .)
    if [[ $DOCKER_CLIENT_MAJOR_VERSION -lt $DOCKER_ENGINE_MAJOR_VERSION ]]; then
        printf "Check failed: Please update Docker client version!\n"
        printf "\tCurrent version: ${DOCKER_CLIENT_VERSION}\n"
        printf "\tRecommended major version: ${DOCKER_ENGINE_MAJOR_VERSION}\n"
    fi

    # Check Docker server version
    DOCKER_SERVER_VERSION=$(docker version --format '{{.Server.Version}}')
    DOCKER_SERVER_MAJOR_VERSION=$(echo $DOCKER_SERVER_VERSION | cut -f1 -d .)
    if [[ $DOCKER_SERVER_MAJOR_VERSION -lt $DOCKER_ENGINE_MAJOR_VERSION ]]; then
        printf "Check failed: Please update Docker server version!\n"
        printf "\tCurrent version: ${DOCKER_SERVER_VERSION}\n"
        printf "\tRecommended major version: ${DOCKER_ENGINE_MAJOR_VERSION}\n"
    fi

    printf "Check passed: Docker Engine version is correct!\n"
else
    printf "Check failed: Please install an updated Docker Engine version!\n" >&2
    exit 1
fi

# Check if Docker Compose is installed
which docker-compose >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    # Check Docker Compose version
    DOCKER_COMPOSE_CURRENT_VERSION=$(docker-compose version --short)
    if [[ $DOCKER_COMPOSE_CURRENT_VERSION != $DOCKER_COMPOSE_VERSION ]]; then
        printf "Check failed: Please update Docker compose version!\n"
        printf "\tCurrent version: ${DOCKER_COMPOSE_CURRENT_VERSION}\n"
        printf "\tRecommended version: ${DOCKER_COMPOSE_VERSION}\n"
    fi
    printf "Check passed: Docker Compose version is correct!\n"
else
    printf "Check failed: Please install an updated Docker Compose version!\n" >&2
    exit 1
fi

# Ensure /var/lib/docker will not cause Docker host to become unusable
mountpoint -- "$(docker info -f '{{ .DockerRootDir }}')" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
    printf "Check failed: Create a separate partition for /var/lib/docker!\n"
    exit 1
else
    printf "Check passed: /var/lib/docker in separate partition!\n"    
fi

# Ensure only authorized users have access to Docker daemon
AUTHORIZED_DOCKER_USER=admin
DOCKER_GROUP=$(getent group docker)
if [[ $? -eq 0 ]]; then
    USER_LIST_STRING=$(echo $DOCKER_GROUP | cut -d ":" -f4)
    IFS=',' read -ra USER_LIST <<< "$USER_LIST_STRING"
    if [[ ${#USER_LIST[@]} -gt 1 ]]; then
        printf "Check failed: Docker group contains more that 1 user: %s\n" \
            $USER_LIST_STRING
        exit 1
    fi
    if [[ "$AUTHORIZED_DOCKER_USER" != "$USER_LIST_STRING" ]]; then
        printf "Check failed: Authorized user is not assigned to Docker group!\n"
        exit 1
    else
        printf "Check passed: Authorized user in Docker group!\n"
    fi
else
    printf "Check failed: No users attached to Docker group!\n"
    exit 1
fi

# Ensure that docker.service file ownership is set to root
FILE=$(systemctl show -p FragmentPath docker.service | cut -d '=' -f2)
if [[ -f "$FILE" ]]; then
    OWNERSHIP=$(stat -c %u:%g $FILE | grep -v 0:0)
    if [[ -n $OWNERSHIP ]]; then
        printf "Check failed: Improper docker.service file ownership\n"
        exit 1
    else
        printf "Check passed: docker.service file ownership is correct!\n"
    fi
else
    printf "Check skipped: docker.service file does not exist!\n"
fi

# Ensure that /etc/docker directory ownership is set to root
DIR=/etc/docker
if [[ -d "$DIR" ]]; then
    OWNERSHIP=$(stat -c %u:%g $DIR | grep -v 0:0)
    if [[ -n $OWNERSHIP ]]; then
        printf "Check failed: Improper /etc/docker directory ownership\n"
        exit 1
    else
        printf "Check passed: /etc/docker directory ownership is correct!\n"
    fi
    
    PERMISSIONS=$(stat -c %a $DIR)
    if [[ "$PERMISSIONS" -le 755 ]]; then
        printf "Check failed: Improper /etc/docker directory permissions\n"
        exit 1
    else
        printf "Check passed: /etc/docker directory permissions are correct!\n"    
    fi
else
    printf "Check skipped: /etc/docker directory does not exist!\n"
fi

## Docker daemon TLS configuration
HOST=server1.scw.lab
IP1=10.10.10.3
IP2=127.0.0.1
FOLDER=docker-tls

mkdir -p $FOLDER

# Generate CA private and public keys
read -sp "Enter CA key password: " CA_KEY_PASSWORD
echo
echo $CA_KEY_PASSWORD | openssl genrsa -aes256 -passout stdin \
    -out $FOLDER/ca-key.pem 4096

openssl req -new -x509 -days 365 -sha256 \
    -key $FOLDER/ca-key.pem \
    -out $FOLDER/ca.pem \
    -subj '/CN=CA/O=SCW/C=AU'

# Generate Server key and CSR
openssl genrsa -out $FOLDER/server-key.pem 4096

openssl req -subj "/CN=$HOST" -sha256 -new \
    -key $FOLDER/server-key.pem \
    -out $FOLDER/server.csr

# Sign server public key with CA
echo subjectAltName = DNS:$HOST,IP:$IP1,IP:$IP1 >> $FOLDER/extfile.cnf
echo extendedKeyUsage = serverAuth >> $FOLDER/extfile.cnf
openssl x509 -req -days 365 -sha256 \
    -in $FOLDER/server.csr \
    -CA $FOLDER/ca.pem \
    -CAkey $FOLDER/ca-key.pem \
    -CAcreateserial \
    -out $FOLDER/server-cert.pem \
    -extfile $FOLDER/extfile.cnf

# Remove temporal files
rm -v $FOLDER/server.csr $FOLDER/extfile.cnf

# Set permissions for private keys
chmod -v 0400 $FOLDER/ca-key.pem $FOLDER/key.pem $FOLDER/server-key.pem

# Set permissions for certificates
chmod -v 0444 $FOLDER/ca.pem $FOLDER/server-cert.pem $FOLDER/cert.pem

# Execute Docker daemon with TLS support
cat <<EOF > /etc/docker/daemon.json
{
  "tls": true,
  "tlscacert": "$FOLDER/ca.pem",
  "tlscert": "$FOLDER/server-cert.pem",
  "tlskey": "$FOLDER/server-key.pem",
  "hosts": ["tcp://0.0.0.0:2376", "unix:///var/run/docker.sock"]
}
EOF

service docker restart

echo
echo
echo "All checks passed!"
exit 0
