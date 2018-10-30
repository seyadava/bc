#!/bin/bash

#################################################################################################################
# Configure an engine signer and run parity. It also runs the node discovery mechanisms to identify boot nodes.
#################################################################################################################

# Utility function to exit with message
unsuccessful_exit()
{
  echo "FATAL: Exiting script due to: $1. Exit code: $2";
  exit $2;
}

setup_cli_certificates()
{
	if [ ! -z $SPN_APPID ]; then
		sudo cp /var/lib/waagent/Certificates.pem /usr/local/share/ca-certificates/azsCertificate.crt
		sudo update-ca-certificates
		export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
		sudo sed -i -e "\$aREQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt" /etc/environment
	fi
}

configure_endpoints()
{
    az cloud register -n AzureStackCloud --endpoint-resource-manager "https://management.$ENDPOINTS_FQDN" --suffix-storage-endpoint "$ENDPOINTS_FQDN" --suffix-keyvault-dns ".vault.$ENDPOINTS_FQDN"
    az cloud set -n AzureStackCloud
    az cloud update --profile 2018-03-01-hybrid
	az login --service-principal -u $SPN_APPID -p $SPN_KEY --tenant $AAD_TENANTID
}

# Upload a blob to azure storage
upload_blob_with_retry()
{
    file=$1;
    blobName=$2;
    storageAccountName=$3;
    storageContainerName=$4;
    accountKey=$5;
    leaseId=$6;
    notries=$7;
	
    success=0
	for loopcount in $(seq 1 $notries); do
        if [ -z $leaseId ]; then
            az storage blob upload -c $storageContainerName -n $blobName -f $file --account-name $storageAccountName --account-key $accountKey;
        else
            az storage blob upload -c $storageContainerName -n $blobName -f $file --lease-id $leaseId --account-name $storageAccountName --account-key $accountKey;
        fi

		if [ $? -ne 0 ]; then
			continue;
		else
			success=1
			break;
		fi
	done
    return $success;
}

# Invoke Parity JSON RPC API via IPC call
invoke_parity_jsonipc_method() {
    local method=$1;
    local paramList=$2;
    local methodId=$3;
    local ipcFilePath=$PARITY_IPC_PATH;
    local ipcCommand='{"jsonrpc":"2.0","method":"'$method'","params":'$paramList',"id":'$methodId'}';
    printf $ipcCommand | nc -U -w 1 -q 1 $ipcFilePath;
}

# Shutdown parity process
shutdown_parity()
{
    kill -9 $(ps aux | grep '[p]arity -' | awk '{print $2}');
    # Give time for the process to stop
    sleep 5;
}


# Returns address given a passphrase.
get_address_from_phrase()
{
    local passphrase=$1;
    local paritylog=$2;
    local maxRetrys=5;
    local currentRetries=0;

    # Start parity in the background
    parity --config none_authority.toml >> $paritylog 2>&1 &
    if [ $? -ne 0 ]; then unsuccessful_exit "Unable to generate address. Parity failed to start." 51; fi

    # Wait for IPC file to open
    sleep $RPC_PORT_WAIT_IN_SECS;
    
    sudo chown :adm $PARITY_IPC_PATH;
    sudo chmod -R g+w $PARITY_IPC_PATH;

    local account=$(invoke_parity_jsonipc_method 'parity_newAccountFromPhrase' '["'$passphrase'","'$passphrase'"]' 0);
    while [ $currentRetries -lt $maxRetrys ] && [ -z "$account" ]; do    
        let currentRetries=currentRetries+1;
        sleep $((5**$currentRetries));
        local account=$(invoke_parity_jsonipc_method 'parity_newAccountFromPhrase' '["'$passphrase'","'$passphrase'"]' 0);
    done
     
    if [ -z "$account" ]; then unsuccessful_exit "Unable to generate address. Maximum number of retries exceeded." 57; fi

    # Parse the result to return just the account address
    local address=$(echo $account | jq -r ".result");

    shutdown_parity # shutdown parity on completion

    echo $address;
}

renew_lease()
{
    blobName=$1;
    storageAccountName=$2;
    storageContainerName=$3;
    accountKey=$4;
    leaseId=$5;

    echo "RENEWWWW======================"
    az storage blob lease renew -b $blobName -c $storageContainerName --lease-id $leaseId --account-name $storageAccountName --account-key $accountKey
}

# Appends enode url of the current node to azure storage blob
publish_enode_url() {
    renew_lease $PASSPHRASE_FILE_NAME $STORAGE_ACCOUNT $CONTAINER_NAME $STORAGE_ACCOUNT_KEY $LEASE_ID
    echo "ALLIIIIIIIIIIIIIIIIIIIII-9-1"
    enodeUrl=$(invoke_parity_jsonipc_method "parity_enode" "[]" 0 | jq -r ".result");
    echo $enodeUrl
    echo "ALLIIIIIIIIIIIIIIIIIIIII-9-2"
    if [[ $enodeUrl =~ ^enode ]]; then
        hostname=$(hostname);
        echo "{\"passphraseUri\": \"${PASSPHRASE_URI}\", \"enodeUrl\": \"${enodeUrl}\", \"hostname\": \"$hostname\"}" > nodeid.json;
        success=$(upload_blob_with_retry "nodeid.json" $PASSPHRASE_FILE_NAME $STORAGE_ACCOUNT $CONTAINER_NAME $STORAGE_ACCOUNT_KEY $LEASE_ID $NOOFTRIES);
	    if [ $? -ne 1 ]; then
            unsuccessful_exit "Unable to publish enode url to azure storage blob after $NOOFTRIES attempts." 52
        fi
    else
        unsuccessful_exit "Parity is not configured properly. The enode url is not valid." 53
    fi
}

add_enode_to_boot_nodes_file() {
    local enodeUrl=$1;
    echo "ALLIIIIIIIIIIIIIIIIIIIII-11-1"
     # Only write to the file when a new boot node is found
    if [ ! -z $(grep "$enodeUrl" "$BOOT_NODES_FILE") ]; then 
        echo "ALLIIIIIIIIIIIIIIIIIIIII-11-2"
        echo "enode already exists in boot node file: $enode";
    else
        echo "ALLIIIIIIIIIIIIIIIIIIIII-11-3"
        echo $enodeUrl >> $BOOT_NODES_FILE;
    fi
    echo "ALLIIIIIIIIIIIIIIIIIIIII-11-4"
}

# Add discovered node to parity and append the enode url to bootnodes file
add_parity_reserved_peer() {
    filename=$1;
    echo "ALLIIIIIIIIIIIIIIIIIIIII-10-1"
    az storage blob download -c $CONTAINER_NAME -n "$filename"  -f "$CONFIGDIR/$filename" --account-name $STORAGE_ACCOUNT --account-key $STORAGE_ACCOUNT_KEY;
    echo "ALLIIIIIIIIIIIIIIIIIIIII-10-2"
    if [ $? -ne 0 ]; then
        echo "Failed to download lease blob $filename." # no need to retry here since we attempt until NUM_BOOT_NODES has been discovered
    else
        echo "ALLIIIIIIIIIIIIIIIIIIIII-10-3"
        enodeUrl=$(cat "$CONFIGDIR/$filename" | jq -r ".enodeUrl");
        echo "Discovered node with enode url: $enodeUrl";
        if [[ $enodeUrl =~ ^enode ]]; then
            echo "ALLIIIIIIIIIIIIIIIIIIIII-10-4"
            invoke_parity_jsonipc_method "parity_addReservedPeer" '["'$enodeUrl'"]' 0
            echo "ALLIIIIIIIIIIIIIIIIIIIII-10-5"
            if [ $? -ne 0 ]; then
                unsuccessful_exit "Failed to add bootnode to parity." 54
            fi
            echo "ALLIIIIIIIIIIIIIIIIIIIII-10-6"
            add_enode_to_boot_nodes_file $enodeUrl;
            echo "ALLIIIIIIIIIIIIIIIIIIIII-10-7"
        else
            echo "enode url value invalid."
        fi
    fi
}


# Discover other nodes in the network and connect to them with parity_addReservedPeer api
discover_nodes() {
    # Get list of active validator node lease blobs
    echo "ALLIIIIIIIIIIIIIIIIIIIII-8-2"
    leaseBlobs=$(az storage blob list --query '[?properties.lease.state==`leased`].name' -c $CONTAINER_NAME --account-name $STORAGE_ACCOUNT --account-key $STORAGE_ACCOUNT_KEY );
    echo $leaseBlobs > activenodes.json;
    echo "ALLIIIIIIIIIIIIIIIIIIIII-8-3"
    # Download lease blob and retrieve the enode url ( if available ) for each active node
    jq -c '.[]' activenodes.json | while read file; do
        echo "ALLIIIIIIIIIIIIIIIIIIIII-8-4"
        leaseBlobName=$(echo $file | tr -d '"');
        echo "=========================="
        echo $leaseBlobName
        echo $PASSPHRASE_FILE_NAME
        echo "=========================="
        echo "ALLIIIIIIIIIIIIIIIIIIIII-8-5"
        if [ "$PASSPHRASE_FILE_NAME" != "$leaseBlobName"  ]; then  # skip if lease is for current node
            echo "ALLIIIIIIIIIIIIIIIIIIIII-8-6"
            add_parity_reserved_peer $leaseBlobName;
        fi
    done
}

discover_more_nodes() {
    echo "ALLIIIIIIIIIIIIIIIIIIIII-81"
    if [ $(wc -l < $BOOT_NODES_FILE) -lt $NUM_BOOT_NODES ]; then echo 1; else echo 0; fi
}

set_ExtraData() {
    # Update the miner ExtraData field    
    echo "Setting parity ExtraData field to $1"
    invoke_parity_jsonipc_method "parity_setExtraData" '["'$1'"]' 1
}

add_remote_peers() {
    cd $HOMEDIR
    networkInfo=$(curl "$CONSORTIUM_DATA_URL/networkinfo")
    echo $networkInfo | jq -c '.bootnodes[]' | while IFS='' read url;do
        enodeUrl=$(echo $url | jq -r '.')
        if [ ! -z $enodeUrl ]; then
            invoke_parity_jsonipc_method "parity_addReservedPeer" '["'$enodeUrl'"]' 0
            echo "Added remote $enodeUrl to parity."

            add_enode_to_boot_nodes_file $enodeUrl;
        fi
    done
}

# configures and run parity.
run_parity()
{

    echo "Passphrase: $PASSPHRASE";
    echo $PASSPHRASE > $PASSWORD_FILE;

    # Inject engine signer address and admin id to node.toml
    echo "ALLIIIIIIIIIIIIIIIIIIIII-1"
    address=$(get_address_from_phrase $PASSPHRASE $PARITY_LOG_FILE_PATH);
    if [ -z $address ]; then
        unsuccessful_exit "Unable to generate validator address from passphrase." 55
    else
        echo "Engine signer: $address";
    fi
    echo "ALLIIIIIIIIIIIIIIIIIIIII-2"
    sed s/#ENGINE_SIGNER/$address/ $HOMEDIR/node.toml > $HOMEDIR/node1.toml;
    sed s/#ETH_RPC_PORT/$RPC_PORT/ $HOMEDIR/node1.toml > $CONFIGDIR/node.toml;

    if [[ $MUST_DEPLOY_GATEWAY == "False" ]]; then
        # Look up the assigned public ip for this VMSS instance using Azure "Instance Metadata Service"
        if [ "$ACCESS_TYPE" != "SPN" ]; then
            local publicIp=$(curl -s -H Metadata:true http://169.254.169.254/metadata/instance?api-version=2017-04-02 | jq -r .network.interface[0].ipv4.ipAddress[0].publicIpAddress);
        else
            local publicIp=$IP_ADDRESS
        fi
        echo "Public IP: " ${publicIp};
        sed -i s/#EXTERNALIP#/$publicIp/ $CONFIGDIR/node.toml;
    else
        # Delete the external IP line
        sed -i /#EXTERNALIP#/d $CONFIGDIR/node.toml;
    fi
    echo "ALLIIIIIIIIIIIIIIIIIIIII-3"
    # Cleanup temp files
    rm -f node1.toml;
    echo "ALLIIIIIIIIIIIIIIIIIIIII-4"
    echo "Starting parity on validator node..."
    parity --config $CONFIGDIR/node.toml --force-ui -lclient,sync,discovery,engine,poa,shutdown,chain,executive=debug >> $PARITY_LOG_FILE_PATH 2>&1 &
    echo "ALLIIIIIIIIIIIIIIIIIIIII-5"
    # Allow time for the Parity client to start
    sleep $RPC_PORT_WAIT_IN_SECS; # Wait for RPC port to open
    
    sudo chown :adm $PARITY_IPC_PATH;
    sudo chmod -R g+w $PARITY_IPC_PATH;
    echo "ALLIIIIIIIIIIIIIIIIIIIII-6"
    # Run tasks
    publish_enode_url;
    set_ExtraData $ADMINID
    echo "ALLIIIIIIIIIIIIIIIIIIIII-7"
    if [ "$MODE" == "Member" ]; then  add_emote_peers; fi
}

####################################################################################
# Parameters : Validate that all arguments are supplied
####################################################################################
if [ $# -lt 15 ]; then unsuccessful_exit "Insufficient parameters supplied." 56; fi

AZUREUSER=$1
STORAGE_ACCOUNT=$2;
CONTAINER_NAME=$3;
STORAGE_ACCOUNT_KEY=$4;
ADMINID=$5;
NUM_BOOT_NODES=$6;
RPC_PORT=$7;
PASSPHRASE=$8
PASSPHRASE_FILE_NAME=$9
PASSPHRASE_URI=${10}
MODE=${11}
LEASE_ID=${12}
CONSORTIUM_DATA_URL=${13}
MUST_DEPLOY_GATEWAY=${14}
PARITY_LOG_FILE_PATH=${15}
ACCESS_TYPE=${16}
ENDPOINTS_FQDN=${17}
SPN_APPID=${18}
SPN_KEY=${19}
AAD_TENANTID=${20}
IP_ADDRESS=${21}


echo "AZUREUSER=$AZUREUSER"
echo "STORAGE_ACCOUNT=$STORAGE_ACCOUNT"
echo "CONTAINER_NAME=$CONTAINER_NAME"
echo "STORAGE_ACCOUNT_KEY=$STORAGE_ACCOUNT_KEY"
echo "ADMINID=$ADMINID"
echo "NUM_BOOT_NODES=$NUM_BOOT_NODES"
echo "RPC_PORT=$RPC_PORT"
echo "PASSPHRASE=$PASSPHRASE"
echo "PASSPHRASE_FILE_NAME=$PASSPHRASE_FILE_NAME"
echo "PASSPHRASE_URI=$PASSPHRASE_URI"
echo "MODE=$MODE"
echo "LEASE_ID=$LEASE_ID"
echo "CONSORTIUM_DATA_URL=$CONSORTIUM_DATA_URL"
echo "MUST_DEPLOY_GATEWAY=$MUST_DEPLOY_GATEWAY"
echo "PARITY_LOG_FILE_PATH=$PARITY_LOG_FILE_PATH"
echo "ACCESS_TYPE=$ACCESS_TYPE"
echo "ENDPOINTS_FQDN=$ENDPOINTS_FQDN"
echo "SPN_APPID=$SPN_APPID"
echo "SPN_KEY=$SPN_KEY"
echo "AAD_TENANTID=$AAD_TENANTID"
echo "IP_ADDRESS=$IP_ADDRESS"

# Constants
NOOFTRIES=3;
HOMEDIR="/home/$AZUREUSER";
CONFIGDIR="$HOMEDIR/config";
SLEEP_INTERVAL_IN_SECS=2;
BOOT_NODES_FILE="$HOMEDIR/bootnodes.txt";
RPC_PORT_WAIT_IN_SECS=15;
POA_NETWORK_UPFILE="$HOMEDIR/networkup.txt";
PASSWORD_FILE="$HOMEDIR/node.pwd";
PARITY_IPC_PATH="/opt/parity/jsonrpc.ipc"

################################################
# Copy required certificates for Azure CLI
################################################
setup_cli_certificates

################################################
# Configure Cloud Endpoints in Azure CLI
################################################
configure_endpoints

# start validator node
run_parity

# discover nodes until enough boot nodes have been found
while sleep $SLEEP_INTERVAL_IN_SECS; do
    echo "ALLIIIIIIIIIIIIIIIIIIIII-0000000"
    if [ $(discover_more_nodes) -eq 1 ]; then 
        discover_nodes; 
    else    
        break;
    fi;

done

echo "poa network started" > $POA_NETWORK_UPFILE 
echo "Successfully started validator node."