#!/bin/bash
if [ "${RANCHER_DEBUG}" == "true" ]; then
    set -x
fi

echo "Starting for Rancher version: ${RANCHER_VERSION}"


if [[ $CATTLE_URL = *"/v1"* ]]; then
    # Create CATTLE_URL for v2-beta
    CATTLE_URL_V2=`echo $CATTLE_URL | sed -e 's_/v1_/v2-beta_'`

    # Create CATTLE_URL for catalog endpoint
    CATTLE_URL_CATALOG=`echo $CATTLE_URL | sed -e 's_/v1_/v1-catalog_'`
else
     # Create CATTLE_URL for v2-beta
    CATTLE_URL_V2=$CATTLE_URL

    # Create CATTLE_URL for catalog endpoint
    CATTLE_URL_CATALOG=`echo $CATTLE_URL | sed -e 's_/v2-beta_/v1-catalog_'`
fi

# Get environment name
ENV_NAME=`curl -s -k 169.254.169.250/latest/self/stack/environment_name`

# Get id from environment name
ENV_ID=`curl -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY -s -k $CATTLE_URL_V2/projects?name=$ENV_NAME | jq -r .data[].id`

# Check for default registry setting (private registry)
REGISTRY=`curl -s -k $CATTLE_URL_V2/settings/registry.default | jq -r .value`

# Find all the infra stacks
INFRASTACKS=`curl -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY -s -k $CATTLE_URL_V2/stacks?system=true\&accountId=$ENV_ID | jq -r .data[].name`

echo -e "Found infrastructure stacks:\n${INFRASTACKS}"

# Loop through all infra stacks to pull the needed images
for STACK in $INFRASTACKS; do
    # Get externalID and strip catalog name to identify stack
    STACKEID=`curl -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY -s -k $CATTLE_URL_V2/stacks?system=true\&accountId=$ENV_ID\&name=$STACK | jq -r .data[].externalId`
    # Example output: catalog://library:infra*ipsec:15
    STACKCATALOGPATH=`echo $STACKEID | sed -e 's_catalog://\(.*\):.*$_\1_'`

    # Check if catalog-service has a reference for this stack
    STACK_VERSIONLINK_CURL=`curl -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY -s -k --write-out "%{http_code}\n" --output /dev/null $CATTLE_URL_CATALOG/templates/$STACKCATALOGPATH?rancherVersion=$RANCHER_VERSION`

    # If curl is unsuccessful, skip to next stack (no catalog present with this stack reference)
    if [ $STACK_VERSIONLINK_CURL -ne 200 ]; then
        echo "Skipping ${STACK}, no catalog reference found in catalog service"
        continue
    fi

    # Get the latest versionLink for $RANCHER_VERSION
    STACK_VERSIONLINK=`curl -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY -s -k $CATTLE_URL_CATALOG/templates/$STACKCATALOGPATH?rancherVersion=$RANCHER_VERSION | jq -r '.versionLinks[]' | tail -1`

    # Check if we need to template
    if `curl -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY -s -k $STACK_VERSIONLINK | jq -e -r '.files | ."docker-compose.yml.tpl"' > /dev/null`; then
        # Get images for versionLink
        STACK_IMAGES=`curl -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY -s -k $STACK_VERSIONLINK | jq -r '.files."docker-compose.yml.tpl"' | gomplate 2>/dev/null | yq r - -j | jq -r '.services[]?.image?, .[]?.image? | select (. != null)' | sort -u`
    else
        # Get images for versionLink
        STACK_IMAGES=`curl -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY -s -k $STACK_VERSIONLINK | jq -r '.files."docker-compose.yml"' | yq r - -j | jq -r '.services[]?.image?, .[]?.image? | select (. != null)' | sort -u`
    fi

    # Check system cpu usage before proceeding
    if [ "${CHECK_CPU_USAGE}" == "true" ]; then
        while [ `top -bn2 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}' | tail -1 | xargs printf "%1.f\n"` -gt $CPU_USAGE_MAX ]; do
            echo "CPU usage higher than ${CPU_USAGE_MAX}%, sleeping ${CPU_USAGE_SLEEP}s"
            sleep $CPU_USAGE_SLEEP
        done
    fi
    

    # Loop images and pull
    for IMAGE in $STACK_IMAGES; do
        if [ -z $REGISTRY ] || [ $REGISTRY == "null" ]; then
            echo "Executing docker pull ${IMAGE}"
            docker pull ${IMAGE}
        else
            echo "Executing docker pull ${REGISTRY}/${IMAGE}"
            docker pull ${REGISTRY}/${IMAGE}
        fi 
        if [ "${RANDOM_SLEEP}" == "true" ]; then
            HOST_COUNT=`curl -s -H "Accept: application/json" 169.254.169.250/latest/hosts | jq -r '[.[] ]| length'`
            HOST_COUNT_SOURCE="$(($HOST_COUNT * 10))"
            SLEEP=$((RANDOM % $HOST_COUNT_SOURCE))
            echo "Random sleep: ${SLEEP}s"
            sleep $SLEEP
        fi
    done
done

echo "Finished"
