#!/bin/bash

METRIC_FILE="/output/gpu_user_metrics.prom"
TEMP_FILE="${METRIC_FILE}.tmp"
HOST_PASSWD="/host/etc/passwd"
EXCLUDED_USERS="gdm systemd"
HOST_INIT_PID="${HOST_INIT_PID:-1}"
HOST_GETENT_TIMEOUT_SECONDS="${HOST_GETENT_TIMEOUT_SECONDS:-2}"
ENABLE_HOST_GETENT_FALLBACK="${ENABLE_HOST_GETENT_FALLBACK:-true}"
UNKNOWN_USER_LABEL="${UNKNOWN_USER_LABEL:-uid_unmapped}"
NVIDIA_SMI_TIMEOUT_SECONDS="${NVIDIA_SMI_TIMEOUT_SECONDS:-5}"
COLLECTION_INTERVAL_SECONDS="${COLLECTION_INTERVAL_SECONDS:-5}"

mkdir -p "$(dirname "$METRIC_FILE")"

declare -A UID_TO_USER
declare -A UID_TO_USER_STATE
declare -A GPU_IDX_MAP
declare -A GPU_NAME_MAP
declare -A GPU_TOTAL_MEM_MAP

log_message() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

run_nvidia_smi_query() {
    local output=""
    local status=0

    NVIDIA_SMI_OUTPUT=""

    if command -v timeout >/dev/null 2>&1; then
        output=$(timeout "${NVIDIA_SMI_TIMEOUT_SECONDS}s" nvidia-smi "$@" 2>/dev/null)
        status=$?
    else
        output=$(nvidia-smi "$@" 2>/dev/null)
        status=$?
    fi

    if [[ "$status" -ne 0 ]]; then
        return "$status"
    fi

    NVIDIA_SMI_OUTPUT="$output"
    return 0
}

sanitize_label_value() {
    local value="$1"
    printf '%s' "$value" | tr -cd '[:print:]' | tr -d '"' | tr -d "'" | tr -d '\\'
}

resolve_cmd_info() {
    local pid="$1"
    local cmdline=""
    local comm=""
    local exe=""
    local cgroup_line=""
    local cgroup_hint=""
    local cgroup_tail=""

    CMD_VALUE="hidden_or_dead"
    CMD_SOURCE="pid_missing"

    if [ ! -d "/proc/$pid" ]; then
        return
    fi

    if [ -r "/proc/$pid/cmdline" ]; then
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | tr -cd '[:print:]')
        if [[ -n "$cmdline" ]]; then
            CMD_VALUE="$cmdline"
            CMD_SOURCE="cmdline"
            return
        fi
    fi

    if [ -r "/proc/$pid/comm" ]; then
        comm=$(tr -d '\n\r' < "/proc/$pid/comm" 2>/dev/null | tr -cd '[:print:]')
        if [[ -n "$comm" ]]; then
            CMD_VALUE="$comm"
            CMD_SOURCE="comm"
            return
        fi
    fi

    if [ -e "/proc/$pid/exe" ]; then
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null | tr -cd '[:print:]')
        if [[ -n "$exe" ]]; then
            CMD_VALUE="$exe"
            CMD_SOURCE="exe"
            return
        fi
    fi

    if [ -r "/proc/$pid/cgroup" ]; then
        while IFS= read -r cgroup_line; do
            cgroup_tail="${cgroup_line##*/}"
            cgroup_tail=$(printf '%s' "$cgroup_tail" | tr -cd '[:alnum:]_.:-')
            if [[ -n "$cgroup_tail" ]]; then
                cgroup_hint="$cgroup_tail"
            fi
        done < "/proc/$pid/cgroup"

        if [[ -n "$cgroup_hint" ]]; then
            CMD_VALUE="cgroup:$cgroup_hint"
            CMD_SOURCE="cgroup"
            return
        fi
    fi

    CMD_VALUE="unknown_command"
    CMD_SOURCE="unknown"
}

lookup_host_user_by_uid() {
    local uid="$1"
    local entry=""
    local username=""

    HOST_USER_NAME=""

    if [[ "$ENABLE_HOST_GETENT_FALLBACK" != "true" ]]; then
        return 1
    fi

    if ! command -v nsenter >/dev/null 2>&1; then
        return 1
    fi

    if command -v timeout >/dev/null 2>&1; then
        entry=$(timeout "${HOST_GETENT_TIMEOUT_SECONDS}s" nsenter -t "$HOST_INIT_PID" -m getent passwd "$uid" 2>/dev/null | head -n 1)
    else
        entry=$(nsenter -t "$HOST_INIT_PID" -m getent passwd "$uid" 2>/dev/null | head -n 1)
    fi

    if [[ -z "$entry" ]]; then
        return 1
    fi

    IFS=: read -r username _ _ _ _ _ _ <<< "$entry"
    if [[ -z "$username" ]]; then
        return 1
    fi

    HOST_USER_NAME="$username"
    return 0
}

resolve_user_info() {
    local uid="$1"

    RESOLVED_USER="$UNKNOWN_USER_LABEL"
    RESOLVED_USER_STATE="uid_only"

    if [[ -z "$uid" ]]; then
        return
    fi

    if [[ -n "${UID_TO_USER_STATE[$uid]+_}" ]]; then
        RESOLVED_USER_STATE="${UID_TO_USER_STATE[$uid]}"
        if [[ "$RESOLVED_USER_STATE" == "passwd" || "$RESOLVED_USER_STATE" == "host_getent" ]]; then
            RESOLVED_USER="${UID_TO_USER[$uid]}"
        fi
        return
    fi

    if lookup_host_user_by_uid "$uid"; then
        UID_TO_USER["$uid"]="$HOST_USER_NAME"
        UID_TO_USER_STATE["$uid"]="host_getent"
        RESOLVED_USER="$HOST_USER_NAME"
        RESOLVED_USER_STATE="host_getent"
        return
    fi

    UID_TO_USER_STATE["$uid"]="uid_only"
}

refresh_user_map() {
    UID_TO_USER=()
    UID_TO_USER_STATE=()
    if [ -f "$HOST_PASSWD" ]; then
        while IFS=: read -r username _ uid _; do
            UID_TO_USER["$uid"]="$username"
            UID_TO_USER_STATE["$uid"]="passwd"
        done < "$HOST_PASSWD"
    fi
}

refresh_gpu_info() {
    local gpu_info=""
    local parsed_count=0
    local uuid=""
    local idx=""
    local name=""
    local total_mem=""
    local -A next_gpu_idx_map=()
    local -A next_gpu_name_map=()
    local -A next_gpu_total_mem_map=()

    if ! run_nvidia_smi_query --query-gpu=uuid,index,name,memory.total --format=csv,noheader,nounits; then
        log_message "failed to refresh GPU inventory via nvidia-smi"
        return 1
    fi

    gpu_info="$NVIDIA_SMI_OUTPUT"

    while IFS=, read -r uuid idx name total_mem; do
        uuid=$(echo "$uuid" | tr -d '[:space:]')
        idx=$(echo "$idx" | tr -d '[:space:]')
        name=$(sanitize_label_value "$(echo "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')")
        total_mem=$(echo "$total_mem" | tr -d '[:space:]')
        
        if [[ -n "$uuid" && -n "$idx" && "$total_mem" =~ ^[0-9]+$ ]]; then
            next_gpu_idx_map["$uuid"]="$idx"
            next_gpu_name_map["$uuid"]="$name"
            next_gpu_total_mem_map["$uuid"]=$(( total_mem * 1024 * 1024 ))
            ((parsed_count++))
        fi
    done <<< "$gpu_info"

    if [[ "$parsed_count" -eq 0 && "${#GPU_IDX_MAP[@]}" -gt 0 ]]; then
        log_message "GPU inventory refresh returned no valid rows; keeping previous GPU map"
        return 1
    fi

    GPU_IDX_MAP=()
    GPU_NAME_MAP=()
    GPU_TOTAL_MEM_MAP=()

    for uuid in "${!next_gpu_idx_map[@]}"; do
        GPU_IDX_MAP["$uuid"]="${next_gpu_idx_map[$uuid]}"
        GPU_NAME_MAP["$uuid"]="${next_gpu_name_map[$uuid]}"
        GPU_TOTAL_MEM_MAP["$uuid"]="${next_gpu_total_mem_map[$uuid]}"
    done

    return 0
}

write_metrics_snapshot() {
    local apps_info=""
    local now_epoch=""
    local pid=""
    local uuid=""
    local used_mem_mb=""
    local user=""
    local raw_uid=""
    local user_state=""
    local uid=""
    local cmd=""
    local cmd_source=""
    local used_mem_bytes=""
    local idx=""
    local name=""
    local total=""
    local process_key=""
    local -A seen_process_keys=()

    if [[ "${#GPU_IDX_MAP[@]}" -eq 0 ]]; then
        log_message "GPU inventory is empty; keeping previous metrics file"
        return 1
    fi

    if ! run_nvidia_smi_query --query-compute-apps=pid,gpu_uuid,used_memory --format=csv,noheader,nounits; then
        log_message "failed to query GPU compute apps; keeping previous metrics file"
        return 1
    fi

    apps_info="$NVIDIA_SMI_OUTPUT"
    now_epoch=$(date +%s)

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
        echo "# HELP gpu_process_probe_info Diagnostic state for GPU process attribution"
        echo "# TYPE gpu_process_probe_info gauge"
        echo "# HELP gpu_user_collector_last_success_unixtime Last successful GPU user metrics collection time"
        echo "# TYPE gpu_user_collector_last_success_unixtime gauge"
        echo "gpu_user_collector_last_success_unixtime $now_epoch"

        if [[ -n "$apps_info" ]]; then
            while IFS=, read -r pid uuid used_mem_mb; do
                pid=$(echo "$pid" | tr -d '[:space:]')
                uuid=$(echo "$uuid" | tr -d '[:space:]')
                used_mem_mb=$(echo "$used_mem_mb" | tr -d '[:space:]')

                if [[ -z "$pid" || -z "$uuid" || ! "$used_mem_mb" =~ ^[0-9]+$ ]]; then
                    continue
                fi

                process_key="${pid}|${uuid}"
                if [[ -n "${seen_process_keys[$process_key]+_}" ]]; then
                    continue
                fi
                seen_process_keys["$process_key"]=1
                
                # 默认值设定，用于捕获异常状态
                user="unreadable_pid"   # 默认无法读取 PID (大概率是命名空间隔离或瞬间死亡)
                raw_uid="unknown"
                user_state="pid_missing"

                # 检查进程目录是否存在
                if [ -d "/proc/$pid" ]; then
                    # 尝试获取 UID
                    uid=$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
                    
                    if [ -n "$uid" ]; then
                        raw_uid="$uid"
                        resolve_user_info "$uid"
                        user="$RESOLVED_USER"
                        user_state="$RESOLVED_USER_STATE"
                    else
                        # 目录存在，但没权限读状态 (极度可疑，可能是权限比当前脚本更高的隐藏进程)
                        user="no_permission"
                        user_state="proc_unreadable"
                    fi
                fi

                resolve_cmd_info "$pid"
                cmd="$CMD_VALUE"
                cmd_source="$CMD_SOURCE"

                # 白名单过滤
                if [[ " ${EXCLUDED_USERS} " == *" ${user} "* ]]; then
                    continue
                fi

                # 安全地剔除单双引号和反斜杠，防止破坏 Prometheus Text 格式
                user=$(sanitize_label_value "${user:0:64}")
                cmd=$(sanitize_label_value "${cmd:0:80}")
                raw_uid=$(sanitize_label_value "${raw_uid:0:32}")
                user_state=$(sanitize_label_value "${user_state:0:32}")
                cmd_source=$(sanitize_label_value "${cmd_source:0:32}")
                
                used_mem_bytes=$(( used_mem_mb * 1024 * 1024 ))
                idx="${GPU_IDX_MAP[$uuid]}"
                name="${GPU_NAME_MAP[$uuid]}"
                
                if [[ -n "$idx" ]]; then
                    echo "gpu_process_memory_usage_bytes{gpu_uuid=\"$uuid\", gpu_index=\"$idx\", gpu_name=\"$name\", user=\"$user\", user_state=\"$user_state\", raw_uid=\"$raw_uid\", pid=\"$pid\", process_name=\"$cmd\"} $used_mem_bytes"
                    echo "gpu_process_probe_info{gpu_uuid=\"$uuid\", gpu_index=\"$idx\", gpu_name=\"$name\", user=\"$user\", pid=\"$pid\", process_name=\"$cmd\", raw_uid=\"$raw_uid\", user_state=\"$user_state\", cmd_source=\"$cmd_source\"} 1"
                fi
            done <<< "$apps_info"
        fi

    } > "$TEMP_FILE"

    return 0
}

refresh_user_map
if ! refresh_gpu_info; then
    log_message "initial GPU inventory refresh failed; will retry in the collection loop"
fi
COUNTER=0

echo "Starting GPU user metrics collection..."
while true; do
    ((COUNTER++))
    if [ "$COUNTER" -gt 60 ] || [[ "${#GPU_IDX_MAP[@]}" -eq 0 ]]; then
        refresh_user_map
        refresh_gpu_info || true
        COUNTER=0
    fi

    if write_metrics_snapshot; then
        mv -f "$TEMP_FILE" "$METRIC_FILE"
    else
        rm -f "$TEMP_FILE"
    fi

    sleep "$COLLECTION_INTERVAL_SECONDS"
done

echo "GPU user metrics collection terminated."
