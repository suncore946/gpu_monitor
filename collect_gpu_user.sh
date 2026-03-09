#!/bin/bash

METRIC_FILE="/output/gpu_user_metrics.prom"
TEMP_FILE="${METRIC_FILE}.tmp"
HOST_PASSWD="/host/etc/passwd"
EXCLUDED_USERS="gdm systemd"

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

echo "Starting GPU user metrics collection..."
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
                
                # 默认值设定，用于捕获异常状态
                user="unreadable_pid"   # 默认无法读取 PID (大概率是命名空间隔离或瞬间死亡)
                cmd="hidden_or_dead"    # 默认命令未知

                # 检查进程目录是否存在
                if [ -d "/proc/$pid" ]; then
                    # 尝试获取 UID
                    uid=$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
                    
                    if [ -n "$uid" ]; then
                        if [ -n "${UID_TO_USER[$uid]}" ]; then
                            user="${UID_TO_USER[$uid]}"
                        else
                            # 捕获到了 UID，但在 passwd 中没有名字 (常见于容器内的自定义用户或异常用户)
                            user="uid_$uid"
                        fi
                    else
                        # 目录存在，但没权限读状态 (极度可疑，可能是权限比当前脚本更高的隐藏进程)
                        user="no_permission"
                    fi

                    # 获取完整的启动命令行 (用于抓捕挖矿病毒的启动参数)
                    if [ -f "/proc/$pid/cmdline" ]; then
                        # cmdline 是用 \0 分隔的，将其替换为空格，并剔除不可见字符
                        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" | tr -cd '[:print:]')
                    fi
                    
                    # 如果 cmdline 为空 (比如内核线程或僵尸进程)，退避使用 comm (短进程名)
                    if [[ -z "$cmd" ]] && [ -f "/proc/$pid/comm" ]; then
                        cmd=$(tr -d '\n\r' < "/proc/$pid/comm" | tr -cd '[:print:]')
                    fi
                    
                    # 如果还是为空
                    if [[ -z "$cmd" ]]; then
                         cmd="unknown_command"
                    fi
                fi

                # 白名单过滤
                if [[ " ${EXCLUDED_USERS} " == *" ${user} "* ]]; then
                    continue
                fi

                # 【格式修正】安全地剔除单双引号和反斜杠，防止破坏 Prometheus Text 格式
                cmd=$(echo "${cmd:0:50}" | tr -d '\"' | tr -d '\'' | tr -d '\\')
                
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

echo "GPU user metrics collection terminated."