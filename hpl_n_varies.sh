#!/bin/bash

set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# Force single-threaded BLAS/OpenMP inside each MPI rank.
# This avoids uncontrolled oversubscription when using mpirun -np 4.
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export GOTO_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export MKL_NUM_THREADS=1

collectl_pids=()

cleanup() {
    for pid in "${collectl_pids[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

usage() {
    cat <<EOF
Usage: $0 <min_percentage> <max_percentage> <step_percentage> <repetitions>

  min_percentage  : minimum percentage of available RAM to use for N
  max_percentage  : maximum percentage of available RAM to use for N
  step_percentage : percentage increment
  repetitions     : number of repetitions for each N

Example:
  $0 10 80 10 5
EOF
    exit 2
}

if [ $# -ne 4 ]; then
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

min_val=$1
max_val=$2
step=$3
repetitions=$4

if (( min_val > max_val )); then
    echo "Error: min_percentage ($min_val) must be <= max_percentage ($max_val)."
    usage
fi

if (( step <= 0 || repetitions <= 0 )); then
    echo "Error: step and repetitions must be > 0."
    usage
fi

if [ ! -f HPL.dat ]; then
    echo "Error: HPL.dat not found in current directory."
    exit 1
fi

generate_n_values() {
    local available_mem_bytes
    available_mem_bytes=$(grep MemAvailable /proc/meminfo | awk '{print $2 * 1024}')
    echo "Available memory (bytes): $available_mem_bytes"

    local pct N used_mem_bytes
    N_values=()

    for (( pct = min_val; pct <= max_val; pct += step )); do
        used_mem_bytes=$(echo "$available_mem_bytes * $pct / 100" | bc -l)
        N=$(echo "scale=0; sqrt($used_mem_bytes / 8)" | bc -l)
        N=$(( (N / 8) * 8 ))
        N_values+=( "$N" )
    done
}

generate_hpl_dat_files() {
    cp HPL.dat HPL.dat.original

    for size in "${N_values[@]}"; do
        local datfile="HPL_${size}.dat"
        local outfile="HPL_${size}.out"
        sed -e "3s|.*|$outfile|" -e "6s|.*|$size Ns|" HPL.dat.original > "$datfile"
        echo "Generated file: $datfile"
    done
}

run_hpl() {
    local size=$1

    collectl --plot --subsys -i 0.01 cCimdn > state_before.csv &
    local before_pid=$!
    collectl_pids+=( "$before_pid" )
    sleep 5
    kill "$before_pid" 2>/dev/null || true

    collectl --plot --subsys -i 0.01 cCimdn > state_during.csv &
    local during_pid=$!
    collectl_pids+=( "$during_pid" )

    cp "HPL_${size}.dat" HPL.dat
    mpirun -np 4 xhpl

    kill "$during_pid" 2>/dev/null || true

    collectl --plot --subsys -i 0.01 cCimdn > state_after.csv &
    local after_pid=$!
    collectl_pids+=( "$after_pid" )
    sleep 5
    kill "$after_pid" 2>/dev/null || true
}

generate_n_values
echo "Problem sizes: ${N_values[*]}"

generate_hpl_dat_files

for size in "${N_values[@]}"; do
    mkdir -p "N${size}"
    for (( rep = 0; rep < repetitions; rep++ )); do
        echo "Running size=$size, repetition=$rep"
        run_hpl "$size"

        mv "HPL_${size}.out" "N${size}/HPL_${size}_rep${rep}.out"
        mv state_before.csv   "N${size}/state_before_rep${rep}.csv"
        mv state_during.csv   "N${size}/state_during_rep${rep}.csv"
        mv state_after.csv    "N${size}/state_after_rep${rep}.csv"
    done
    mv "HPL_${size}.dat" "N${size}/HPL_${size}.dat"
done

echo "All N experiments completed."
