# Raspberry Pi HPL Experiment Pipeline

This repository contains scripts to compile HPL with OpenBLAS/OpenMPI, execute controlled HPL experiments on Raspberry Pi computers, and prepare data for building a performance prediction model.

The intended prediction model is based on three groups of variables:

1. **Machine characteristics**: Raspberry Pi model, RAM size, CPU, compiler, OS, OpenBLAS/MPI version, etc.
2. **HPL parameters**: `N`, `NB`, process grid, number of MPI processes, etc.
3. **Current machine state**: CPU stress, temperature, throttling state, resource usage collected during execution.

The scripts assume they are executed inside the directory that contains `xhpl`, `HPL.dat`, and the experiment scripts.

---

## 1. Compilation script

### Script

```text
hpl_compilation_openblas.sh
```

### Purpose

This script installs the packages needed to build HPL, downloads HPL 2.3, configures it to use OpenMPI and OpenBLAS, compiles it, and records compilation metadata.

### What it installs

The script installs packages such as:

```text
gcc
gfortran
make
wget
tar
sed
lsb-release
pkg-config
openmpi-bin
libopenmpi-dev
libopenblas-dev
```

These provide:

- C compiler;
- Fortran compiler/runtime, needed by OpenBLAS/LAPACK linkage;
- OpenMPI tools and development headers;
- OpenBLAS development library;
- basic build utilities.

### Optimization flags

The script defines:

```bash
OPT_FLAGS="-O3 -march=native -ffast-math -fopenmp -mtune=native"
```

Meaning:

- `-O3`: aggressive optimization;
- `-march=native`: compile for the current CPU architecture;
- `-mtune=native`: tune scheduling for the current CPU;
- `-ffast-math`: allow faster but less strict floating-point transformations;
- `-fopenmp`: enable OpenMP support at compilation/linking time.

For benchmarking on one specific machine, `-march=native` is useful. If you want binaries portable across different Raspberry Pi models, you may prefer architecture-specific or more conservative flags.

### MPI detection

The script detects MPI flags with:

```bash
mpicc --showme:compile
mpicc --showme:link
```

If these commands do not return flags, it falls back to generic OpenMPI include/library paths.

### OpenBLAS detection

The script first tries:

```bash
pkg-config --libs openblas
```

If that fails, it looks for `libopenblas.so` via `ldconfig`.

It also ensures that `-lgfortran` is present in the linker flags, because OpenBLAS/LAPACK may need the Fortran runtime.

### HPL download and compilation

The script removes any previous `hpl-2.3` directory, downloads:

```text
http://www.netlib.org/benchmark/hpl/hpl-2.3.tar.gz
```

then:

1. extracts the archive;
2. runs `setup/make_generic`;
3. creates `Make.rpi`;
4. edits `Make.rpi` using `sed`;
5. sets OpenMPI and OpenBLAS flags;
6. runs:

```bash
make arch=rpi
```

### Compilation metadata

After compilation, the script creates:

```text
hpl_compilation_info.csv
```

containing:

```text
compiler_name
compiler_version
compiler_flags
mpi_version
openblas_version
hpl_version
os_info
compilation_date
```

This file is important for reproducibility and should be preserved with the experimental results.

### How to run

```bash
chmod +x hpl_compilation_openblas.sh
./hpl_compilation_openblas.sh
```

After successful compilation, the HPL executable is normally found inside:

```text
hpl-2.3/bin/rpi/xhpl
```

You should run the experiment scripts from the directory that contains `xhpl` and `HPL.dat`.

---

## 2. Main execution scripts

### 2.1 `hpl_n_varies.sh`

### Purpose

Vary the HPL problem size `N`.

The script computes `N` values from a percentage of currently available RAM. For each percentage, it computes approximately:

```text
N ~= sqrt(available_memory_bytes * percentage / 100 / 8)
```

because an HPL matrix of size `N x N` in double precision uses approximately:

```text
N² * 8 bytes
```

The resulting `N` is rounded down to a multiple of 8.

### Usage

```bash
./hpl_n_varies.sh <min_percentage> <max_percentage> <step_percentage> <repetitions>
```

Example:

```bash
./hpl_n_varies.sh 10 80 10 5
```

This means:

- start at 10% of available RAM;
- go up to 80%;
- use a 10% step;
- run 5 repetitions for each `N`.

### Output

For each `N`, the script creates a directory:

```text
N<N>/
```

Example:

```text
N13792/
```

Inside it, it saves:

```text
HPL_<N>_rep0.out
HPL_<N>_rep1.out
...
state_before_rep0.csv
state_during_rep0.csv
state_after_rep0.csv
temperature_rep0.csv
HPL_<N>.dat
```

The `HPL_<N>.dat` file is the exact HPL configuration used for that `N`.

---

### 2.2 `find_best_n.py`

### Purpose

Analyze the results produced by `hpl_n_varies.sh` and find the best `N`.

A candidate `N` is valid only if it completed all expected repetitions. This avoids selecting an `N` that produced one good result but failed in other repetitions.

### Usage

```bash
python3 find_best_n.py --root . --repetitions <expected_repetitions>
```

Example:

```bash
python3 find_best_n.py --root . --repetitions 5
```

### Output

```text
n_performance_summary.csv
best_n.env
```

`n_performance_summary.csv` contains one line per `N`, including whether the result is complete.

`best_n.env` contains shell variables:

```bash
BEST_N=<value>
BEST_N_MEAN_GFLOPS=<value>
```

It is used automatically by the pipeline script.

---

### 2.3 `hpl_nb_varies.sh`

### Purpose

Vary the HPL block size `NB` for a fixed `N`.

`NB` affects the blocking strategy used by HPL and can influence cache usage and BLAS efficiency.

### Usage

```bash
./hpl_nb_varies.sh <N> <min_NB> <max_NB> <step_NB> <repetitions>
```

Example:

```bash
./hpl_nb_varies.sh 13792 64 256 32 5
```

This tests:

```text
NB = 64, 96, 128, 160, 192, 224, 256
```

for:

```text
N = 13792
```

with 5 repetitions each.

### Output

For each `NB`, the script creates:

```text
N<N>_NB<NB>/
```

Example:

```text
N13792_NB128/
```

Inside it:

```text
HPL_N13792_NB128_rep0.out
HPL_N13792_NB128_rep1.out
...
state_before_rep0.csv
state_during_rep0.csv
state_after_rep0.csv
temperature_rep0.csv
HPL_N13792_NB128.dat
```

---

### 2.4 `find_best_nb.py`

### Purpose

Analyze the results produced by `hpl_nb_varies.sh` and find the best `NB`.

A candidate `NB` is valid only if it completed all expected repetitions.

### Usage

```bash
python3 find_best_nb.py --root . --n <N> --repetitions <expected_repetitions>
```

Example:

```bash
python3 find_best_nb.py --root . --n 13792 --repetitions 5
```

### Output

```text
nb_performance_summary.csv
best_nb.env
```

`best_nb.env` contains:

```bash
BEST_NB=<value>
BEST_NB_MEAN_GFLOPS=<value>
```

---

### 2.5 `hpl_stress.sh`

### Purpose

Run HPL with fixed `N` and `NB`, while varying the number of CPU cores under artificial stress.

This is used to model the impact of machine state / CPU contention on HPL performance.

### Usage

```bash
./hpl_stress.sh <repetitions> <min_stress_cpus> <max_stress_cpus> <N> <NB>
```

Example:

```bash
./hpl_stress.sh 5 1 4 13792 128
```

This runs:

```text
S = 1, 2, 3, 4
```

where `S` is the number of CPUs loaded with `stress`.

### Output

For each stress level:

```text
S<S>N<N>_NB<NB>/
```

Example:

```text
S4N13792_NB128/
```

Inside it:

```text
HPL_N13792_NB128_rep0.out
HPL_N13792_NB128_rep1.out
...
state_before_rep0.csv
state_during_rep0.csv
state_after_rep0.csv
temperature_rep0.csv
HPL_N13792_NB128.dat
```

### Important note about `stress`

The script intentionally kills visible `stress` processes before and after each run using `killall stress` / `pkill -x stress`.

Do not run two stress campaigns at the same time with the same user, because one campaign may kill the `stress` process of the other.

---

## 3. Full experiment pipeline

### Script

```text
hpl_experiment_pipeline.sh
```

### Purpose

Run the full experiment sequence automatically:

1. Run `hpl_n_varies.sh`.
2. Select the best complete `N` with `find_best_n.py`.
3. Run `hpl_nb_varies.sh` using that `N`.
4. Select the best complete `NB` with `find_best_nb.py`.
5. Run `hpl_stress.sh` using the selected `N` and `NB`, with `S = 1..nproc --all`.

### Usage

```bash
./hpl_experiment_pipeline.sh <n_min_pct> <n_max_pct> <n_step_pct> <n_repetitions> \
<nb_min> <nb_max> <nb_step> <nb_repetitions> <stress_repetitions>
```

Example:

```bash
./hpl_experiment_pipeline.sh 10 80 10 5 64 256 32 5 5
```

Meaning:

- `N` stage:
  - 10% to 80% of available RAM;
  - step 10%;
  - 5 repetitions.
- `NB` stage:
  - 64 to 256;
  - step 32;
  - 5 repetitions.
- `stress` stage:
  - 5 repetitions per stress level;
  - stress from 1 CPU to all CPUs detected with `nproc --all`.

---

## 4. Dependency checking

The pipeline script checks for required commands before starting:

```text
awk
bc
collectl
grep
killall
mpirun
nproc
pkill
python3
sed
stress
```

It also checks that the Python standard modules used by `find_best_n.py` and `find_best_nb.py` can be imported.

If `analyze_rpi_hpl.py` is present, it also checks for `matplotlib`, but only as a warning because it is required for plotting, not for running the experiment pipeline.

---

## 5. Temperature and throttling monitoring

The execution scripts create a temperature log for every repetition:

```text
temperature_rep0.csv
temperature_rep1.csv
...
```

Format:

```text
timestamp;phase;temperature_celsius;throttled
2026-06-26 17:10:01;before;48.125;0x0
2026-06-26 17:10:06;during;51.250;0x0
2026-06-26 17:12:32;after;58.000;0x0
```

### Phases

```text
before
during
after
```

- `before`: pre-HPL monitoring window;
- `during`: HPL execution;
- `after`: post-HPL monitoring window.

### Temperature source priority

The scripts try:

1. `/sys/class/thermal/thermal_zone0/temp`
2. any `/sys/class/thermal/thermal_zone*/temp`
3. `vcgencmd measure_temp`
4. `NaN` if no source is available

### Throttling

If `vcgencmd` is available, the script also records:

```bash
vcgencmd get_throttled
```

Otherwise, the `throttled` column is filled with:

```text
NaN
```

### Sampling interval

The default temperature interval is 1 second.

You can override it with:

```bash
TEMP_INTERVAL=2 ./hpl_n_varies.sh 10 80 10 5
```

or with the full pipeline:

```bash
TEMP_INTERVAL=2 ./hpl_experiment_pipeline.sh 10 80 10 5 64 256 32 5 5
```

If you do not specify `TEMP_INTERVAL`, the default value is used.

---

## 6. Running safely with nohup over SSH / PuTTY

If you start the experiment from an SSH session and then close the session, use `nohup` with full redirection:

```bash
cd /path/to/xhpl/directory
chmod +x *.sh *.py

LOG="hpl_pipeline_$(date +%F_%H-%M-%S).log"

nohup ./hpl_experiment_pipeline.sh 10 80 10 5 64 256 32 5 5 \
  > "$LOG" 2>&1 < /dev/null &

echo $! > hpl_pipeline.pid
echo "$LOG" > hpl_pipeline.logname
disown
```

After this, you can close PuTTY / SSH.

### Explanation

```bash
nohup
```

keeps the process running after the SSH session closes.

```bash
> "$LOG"
```

redirects standard output to a log file.

```bash
2>&1
```

redirects standard error to the same log file.

```bash
< /dev/null
```

disconnects standard input from the SSH terminal.

```bash
&
```

runs the command in the background.

```bash
disown
```

removes the job from the shell job table.

### Check status after reconnecting

```bash
cd /path/to/xhpl/directory

cat hpl_pipeline.pid
ps -p "$(cat hpl_pipeline.pid)" -o pid,ppid,stat,etime,cmd
tail -f "$(cat hpl_pipeline.logname)"
```

### Check active processes

```bash
pgrep -a -f 'hpl_experiment_pipeline|hpl_n_varies|hpl_nb_varies|hpl_stress|mpirun|xhpl'
```

---

## 7. Output summary

After the full pipeline, you should have:

### N exploration

```text
N<N>/
n_performance_summary.csv
best_n.env
```

### NB exploration

```text
N<N>_NB<NB>/
nb_performance_summary.csv
best_nb.env
```

### Stress exploration

```text
S<S>N<N>_NB<NB>/
```

Each experiment directory contains:

```text
*.out
state_before_repX.csv
state_during_repX.csv
state_after_repX.csv
temperature_repX.csv
HPL_*.dat
```

The saved `HPL_*.dat` files are important because they preserve the exact HPL configuration used in each experiment.

---

## 8. Why the best-selection scripts are Python

The scripts:

```text
find_best_n.py
find_best_nb.py
```

are written in Python because they need to:

- scan many directories;
- parse filenames;
- verify that all repetitions are present;
- extract GFLOPS from HPL output;
- compute mean GFLOPS;
- ignore incomplete configurations;
- write CSV summaries;
- write `.env` files used by the shell pipeline.

This can be done in shell, but it is more fragile and harder to maintain.

The Python scripts use only the Python standard library. No external Python packages are required for them.

---

## 9. Important methodological notes

### BLAS/OpenMP threads

The execution scripts force:

```bash
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export GOTO_NUM_THREADS=1
export BLIS_NUM_THREADS=1
export MKL_NUM_THREADS=1
```

This avoids uncontrolled oversubscription when using:

```bash
mpirun -np 4 xhpl
```

The intended baseline is:

```text
4 MPI ranks x 1 BLAS thread per rank
```

### Do not run two pipelines in the same directory

The scripts temporarily overwrite files such as:

```text
HPL.dat
state_before.csv
state_during.csv
state_after.csv
temperature.csv
```

They are moved into result directories after each repetition.

Running two pipelines in the same directory can corrupt results.

### Do not run simultaneous stress campaigns

`hpl_stress.sh` kills visible `stress` processes to avoid leaving them running forever. This is intentional, but it means concurrent stress experiments may interfere with each other.

---

## 10. Suggested workflow

A typical full workflow is:

```bash
# 1. Compile HPL
./hpl_compilation_openblas.sh

# 2. Go to the HPL binary directory
cd hpl-2.3/bin/rpi

# 3. Copy scripts and make them executable
chmod +x *.sh *.py

# 4. Run the pipeline with nohup
LOG="hpl_pipeline_$(date +%F_%H-%M-%S).log"

nohup ./hpl_experiment_pipeline.sh 10 80 10 5 64 256 32 5 5 \
  > "$LOG" 2>&1 < /dev/null &

echo $! > hpl_pipeline.pid
echo "$LOG" > hpl_pipeline.logname
disown

# 5. Later, reconnect and check
tail -f "$(cat hpl_pipeline.logname)"
```
