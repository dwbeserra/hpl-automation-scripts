#!/bin/bash

set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# Force single-threaded BLAS/OpenMP inside each MPI rank.
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export GOTO_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export MKL_NUM_THREADS=1

# Temperature monitoring interval in seconds.
# Can be overridden when launching the script, e.g. TEMP_INTERVAL=2 ./hpl_n_varies.sh ...
TEMP_INTERVAL="${TEMP_INTERVAL:-1}"
temp_pids=()

find_temp_file() {
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        echo "/sys/class/thermal/thermal_zone0/temp"
        return 0
    fi

    for f in /sys/class/thermal/thermal_zone*/temp; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done

    return 1
}

read_cpu_temp() {
    local temp_file
    if temp_file=$(find_temp_file 2>/dev/null); then
        awk '{printf "%.3f\n", $1 / 1000}' "$temp_file"
    elif command -v vcgencmd >/dev/null 2>&1; then
        vcgencmd measure_temp | sed "s/temp=//; s/'C//"
    else
        echo "NaN"
    fi
}

read_throttled() {
    if command -v vcgencmd >/dev/null 2>&1; then
        vcgencmd get_throttled 2>/dev/null | sed 's/throttled=//'
    else
        echo "NaN"
    fi
}

init_temperature_log() {
    local output_file="$1"
    echo "timestamp;phase;temperature_celsius;throttled" > "$output_file"
}

write_temperature_sample() {
    local output_file="$1"
    local phase="$2"
    local ts temp throttled

    ts=$(date '+%F %T')
    temp=$(read_cpu_temp)
    throttled=$(read_throttled)

    echo "${ts};${phase};${temp};${throttled}" >> "$output_file"
}

monitor_temperature() {
    local output_file="$1"
    local phase="$2"
    local interval="$3"

    while true; do
        write_temperature_sample "$output_file" "$phase"
        sleep "$interval"
    done
}


collectl_pids=()

cleanup() {
    for pid in "${collectl_pids[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${temp_pids[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

usage() {
    cat <<EOF
Usage: $0 <N> <min_NB> <max_NB> <step_NB> <repetitions>

  N           : fixed HPL problem size
  min_NB      : minimum HPL NB value
  max_NB      : maximum HPL NB value
  step_NB     : NB increment
  repetitions : number of repetitions for each NB

Example:
  $0 15848 64 256 32 5
EOF
    exit 2
}

if [ $# -ne 5 ]; then
    echo "Error: wrong number of arguments."
    usage
fi

re='^[0-9]+$'
for arg in "$@"; do
    if ! [[ $arg =~ $re ]]; then
        echo "Error: '$arg' is not a positive integer."
        usage
    fi
done

N=$1
min_nb=$2
max_nb=$3
step_nb=$4
repetitions=$5

if (( min_nb > max_nb )); then
    echo "Error: min_NB ($min_nb) must be <= max_NB ($max_nb)."
    usage
fi

if (( N <= 0 || step_nb <= 0 || repetitions <= 0 )); then
    echo "Error: N, step_NB and repetitions must be > 0."
    usage
fi

generate_nb_values() {
    NB_values=()
    for (( nb = min_nb; nb <= max_nb; nb += step_nb )); do
        NB_values+=( "$nb" )
    done
    echo "N fixed at: $N"
    echo "NB values: ${NB_values[*]}"
}

generate_hpl_dat_files() {
    cp HPL.dat HPL.dat.original

    for nb in "${NB_values[@]}"; do
        local datfile="HPL_N${N}_NB${nb}.dat"
        local outfile="HPL_N${N}_NB${nb}.out"

        # Standard HPL.dat layout:
        # line 3: output file
        # line 6: N
        # line 8: NB
        sed -e "3s|.*|$outfile|" \
            -e "6s|.*|$N Ns|" \
            -e "8s|.*|$nb NBs|" \
            HPL.dat.original > "$datfile"

        echo "Generated file: $datfile"
    done
}

run_hpl() {
    local nb=$1

    init_temperature_log temperature.csv

    monitor_temperature temperature.csv before "$TEMP_INTERVAL" &
    local temp_before_pid=$!
    temp_pids+=( "$temp_before_pid" )

    collectl --plot --subsys -i 0.01 cCimdn > state_before.csv &
    local before_pid=$!
    collectl_pids+=( "$before_pid" )
    sleep 5
    kill "$before_pid" 2>/dev/null || true
    kill "$temp_before_pid" 2>/dev/null || true

    monitor_temperature temperature.csv during "$TEMP_INTERVAL" &
    local temp_during_pid=$!
    temp_pids+=( "$temp_during_pid" )

    collectl --plot --subsys -i 0.01 cCimdn > state_during.csv &
    local during_pid=$!
    collectl_pids+=( "$during_pid" )

    cp "HPL_N${N}_NB${nb}.dat" HPL.dat
    mpirun -np 4 xhpl

    kill "$during_pid" 2>/dev/null || true
    kill "$temp_during_pid" 2>/dev/null || true

    monitor_temperature temperature.csv after "$TEMP_INTERVAL" &
    local temp_after_pid=$!
    temp_pids+=( "$temp_after_pid" )

    collectl --plot --subsys -i 0.01 cCimdn > state_after.csv &
    local after_pid=$!
    collectl_pids+=( "$after_pid" )
    sleep 5
    kill "$after_pid" 2>/dev/null || true
    kill "$temp_after_pid" 2>/dev/null || true
}

generate_nb_values
generate_hpl_dat_files

for nb in "${NB_values[@]}"; do
    dir="N${N}_NB${nb}"
    mkdir -p "$dir"
    for (( rep = 0; rep < repetitions; rep++ )); do
        echo "Running N=$N, NB=$nb, repetition=$rep"
        run_hpl "$nb"

        mv "HPL_N${N}_NB${nb}.out" "$dir/HPL_N${N}_NB${nb}_rep${rep}.out"
        mv state_before.csv        "$dir/state_before_rep${rep}.csv"
        mv state_during.csv        "$dir/state_during_rep${rep}.csv"
        mv state_after.csv         "$dir/state_after_rep${rep}.csv"
        mv temperature.csv         "$dir/temperature_rep${rep}.csv"
    done
    mv "HPL_N${N}_NB${nb}.dat" "$dir/HPL_N${N}_NB${nb}.dat"
done

echo "All NB experiments completed."
