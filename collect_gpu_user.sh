#!/bin/bash

METRIC_FILE="/output/gpu_user_metrics.prom"
TEMP_FILE="${METRIC_FILE}.tmp"
HOST_PASSWD="/host/etc/passwd"

# 使用空格分隔用户名
EXCLUDED_USERS="ollama root gdm systemd"

mkdir -p $(dirname "$METRIC_FILE")

declare -A UID_TO_USER
declare -A GPU_IDX_MAP
declare -A GPU_NAME_MAP
declare -A GPU_TOTAL_MEM_MAP

refresh_user_map() {
    UID_TO_USER=()
    if [ -f "$HOST_PASSWD" ]; then
        while IFS=: read -r username _ uid _; do
            UID_TO_USER["$uid"]="$username"
        done < "$HOST_PASSWD"
    fi
}

refresh_gpu_info() {
    GPU_IDX_MAP=()
    GPU_NAME_MAP=()
    GPU_TOTAL_MEM_MAP=()
    
    local GPU_INFO
    GPU_INFO=$(nvidia-smi --query-gpu=uuid,index,name,memory.total --format=csv,noheader,nounits)

    while IFS=, read -r uuid idx name total_mem; do
        uuid=$(echo "$uuid" | tr -d '[:space:]')
        idx=$(echo "$idx" | tr -d '[:space:]')
        name=$(echo "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        total_mem=$(echo "$total_mem" | tr -d '[:space:]')
        
        if [[ -n "$uuid" ]]; then
            GPU_IDX_MAP["$uuid"]="$idx"
            GPU_NAME_MAP["$uuid"]="$name"
            GPU_TOTAL_MEM_MAP["$uuid"]=$(( total_mem * 1024 * 1024 ))
        fi
    done <<< "$GPU_INFO"
}

refresh_user_map
refresh_gpu_info
COUNTER=0

while true; do
    ((COUNTER++))
    if [ "$COUNTER" -gt 60 ]; then
        refresh_user_map
        refresh_gpu_info
        COUNTER=0
    fi

    {
        echo "# HELP gpu_memory_total_bytes Total memory of the GPU in bytes"
        echo "# TYPE gpu_memory_total_bytes gauge"
        
        for uuid in "${!GPU_TOTAL_MEM_MAP[@]}"; do
            idx="${GPU_IDX_MAP[$uuid]}"
            name="${GPU_NAME_MAP[$uuid]}"
            total="${GPU_TOTAL_MEM_MAP[$uuid]}"
            if [[ -n "$total" ]]; then
                echo "gpu_memory_total_bytes{gpu_uuid=\"$uuid\", gpu_index=\"$idx\", gpu_name=\"$name\"} $total"
            fi
        done

        echo "# HELP gpu_process_memory_usage_bytes Memory usage per process with user info"
        echo "# TYPE gpu_process_memory_usage_bytes gauge"

        APPS_INFO=$(nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory --format=csv,noheader,nounits)
        
        if [[ -n "$APPS_INFO" ]]; then
            while IFS=, read -r pid uuid used_mem_mb; do
                pid=$(echo "$pid" | tr -d '[:space:]')
                uuid=$(echo "$uuid" | tr -d '[:space:]')
                used_mem_mb=$(echo "$used_mem_mb" | tr -d '[:space:]')

                if [[ -z "$pid" || -z "$uuid" ]]; then continue; fi
                
                user="unknown"
                cmd="unknown"
                if [ -d "/proc/$pid" ]; then
                    uid=$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
                    if [ -n "$uid" ] && [ -n "${UID_TO_USER[$uid]}" ]; then
                        user="${UID_TO_USER[$uid]}"
                    else
                        user="uid_$uid"
                    fi
                    # 如果当前 user 存在于 EXCLUDED_USERS 列表中，则跳过本次循环
                    # 这里使用了 bash 字符串匹配技巧：给两边加上空格来确保完全匹配
                    if [[ " ${EXCLUDED_USERS} " == *" ${user} "* ]]; then
                        continue
                    fi

                    if [ -f "/proc/$pid/comm" ]; then
                        cmd=$(tr -d '\n\r' < "/proc/$pid/comm" | tr -cd '[:print:]')
                        cmd=${cmd:0:20}
                    fi
                fi

                used_mem_bytes=$(( used_mem_mb * 1024 * 1024 ))
                idx="${GPU_IDX_MAP[$uuid]}"
                name="${GPU_NAME_MAP[$uuid]}"
                
                if [[ -n "$idx" ]]; then
                    echo "gpu_process_memory_usage_bytes{gpu_uuid=\"$uuid\", gpu_index=\"$idx\", gpu_name=\"$name\", user=\"$user\", pid=\"$pid\", process_name=\"$cmd\"} $used_mem_bytes"
                fi
            done <<< "$APPS_INFO"
        fi

    } > "$TEMP_FILE"

    mv -f "$TEMP_FILE" "$METRIC_FILE"
    sleep 5
done