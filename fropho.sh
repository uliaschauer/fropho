#!/bin/bash

function run_calc {

	calc_name=$1

	if [ $cluster -eq 1 ]; then
		if [ $brutus -eq 1 ]; then
			cat > $calc_name.job << EOF
#!/bin/bash
#BSUB -n $cpus
#BSUB -R "rusage[mem=1024]"
#BSUB -W $walltime
#BSUB -o %J.o
#BSUB -e %J.e
#BSUB -J $calc_name

mpirun vasp-5.2.11 > log
EOF
			bsub < $calc_name.job
		fi
	else
		echo "Running vasp on $cpus cpus for $calc_name"
		mpirun -np $cpus vasp | tee -a log
	fi
}

USAGE="Usage: `basename $0` [-hv] [-d 'dima dimb dimc'] [-q 'qa qb qc'] [-m mode] [-i min] [-a max] [-s step] [-c cpus] [-w walltime]"

#set defaults
mode=-1
min=-1
max=-1
increment=-1
dim_a=-1
dim_b=-1
dim_c=-1
q_a=-1
q_b=-1
q_c=-1
cpus=12
walltime="1:00"

# Parse command line options.
while getopts hvm:i:a:s:d:q:c:w: OPT; do
    case "$OPT" in
        h)
            echo $USAGE
            exit 0
            ;;
        v)
            echo "`basename $0` version 0.1"
            exit 0
            ;;
        m)
            mode=$OPTARG
            ;;
	i)
	    min=$OPTARG
	    ;;
	a)
	    max=$OPTARG
	    ;;
	s)
	    increment=$OPTARG
	    ;;
	d)
	    dim_a=$(echo $OPTARG | awk '{print $1}')
	    dim_b=$(echo $OPTARG | awk '{print $2}')
	    dim_c=$(echo $OPTARG | awk '{print $3}')
	    ;;
	q)
	    if [ "$OPTARG" == "G" ]; then
			q_a=0
			q_b=0
			q_c=0
	    elif [ "$OPTARG" == "X" ]; then
		q_a=0.5
                q_b=0
                q_c=0
	    elif [ "$OPTARG" == "M" ]; then
                q_a=0.5
                q_b=0.5
                q_c=0
        elif [ "$OPTARG" == "R" ]; then
                q_a=0.5
                q_b=0.5
                q_c=0.5
        else
		q_a=$(echo "$OPTARG" | awk '{print $1}')
		q_b=$(echo "$OPTARG" | awk '{print $2}')
	    	q_c=$(echo "$OPTARG" | awk '{print $3}')
	    fi
	    ;;
	c)
	    cpus=$OPTARG
	    ;;
	w)
	    walltime=$OPTARG
	    ;;
    \?)
		# getopts issues an error message
        echo $USAGE >&2
        exit 1
        ;;
    esac
done

# Remove the switches we parsed above.
shift `expr $OPTIND - 1`

#see if we are on a cluster or not
#ATTENTION: this needs to be amended for every new cluster
cluster=0
brutus=0
if [[ $(hostname) == brutus* ]]; then
	cluster=1
	brutus=1
fi

#make sure at least dimensions are set and are integers
if [ $dim_a -eq -1 ] || [ $dim_b -eq -1 ] || [ $dim_c -eq -1 ]; then
	echo "Please set the dimensions properly"
	exit
else
	test $dim_a -eq 0 2>/dev/null
	if [ $? -eq 2 ]; then
		echo "a dimension is not an integer!"
		exit
	fi
	test $dim_b -eq 0 2>/dev/null
	if [ $? -eq 2 ]; then
		echo "b dimension is not an integer!"
		exit
	fi
	test $dim_c -eq 0 2>/dev/null
	if [ $? -eq 2 ]; then
		echo "c dimension is not an integer!"
		exit
	fi
fi

#echo the parameters
echo "**********************************************************************************"
echo "* Fropho <-> the frozen phonon utility                                           *"
echo "**********************************************************************************"
echo "Creating cell with dimensions:             $dim_a x $dim_b x $dim_c"
if [ $q_a != -1 ] && [ $q_b != -1 ] && [ $q_c != -1 ]; then
	echo "Visualization and modulation for q-point: ($q_a, $q_b, $q_c)"
	if [ $mode -ne -1 ] && [ ! $min == -1 ] && [ ! $max == -1 ] && [ ! $increment == -1 ]; then
		echo "Mode to be modulated:                      $mode"
		echo "Modulation range:                          $min -> $max @ $increment increments"
	else
		echo "*** Insufficient input for modulation"
	fi
else
	echo "*** Insufficient input for visualization"
fi
echo "Number of CPUs:                            $cpus"
if [ $cluster -eq 1 ]; then
	if [ $brutus -eq 1 ]; then
		echo "Running on brutus with walltime:           $walltime"
	fi
else
	echo "Running locally without walltime limit"
fi
echo "**********************************************************************************"
echo ""

#make sure this is not run inside a dim directory (common mistake)
#if yes, skip up one level
if [ $(basename $PWD | awk 'BEGIN{FS="_"}{if ($1 == "dim")print 1; else print 0}') -eq 1 ]; then
	echo "You seem to be running this script inside a dim_*_*_* directory"
	echo "I will cd .. before continuing execution"
	cd ..
	echo ""
fi

#make sure required files are here
if [ ! -f INCAR ] || [ ! -f KPOINTS ] || [ ! -f POSCAR ] || [ ! -f POTCAR ]; then
	echo "This script requires the following files to be present: INCAR, KPOINTS, POSCAR, POTCAR"
	exit
fi


#TODO should run some sanity checks on the files here


#move everything into dim_da_db_dc directories
dim_dir="dim_${dim_a}_${dim_b}_${dim_c}"
if [ ! -d $dim_dir ]; then
	mkdir $dim_dir
	cp INCAR KPOINTS POSCAR POTCAR $dim_dir/
fi
cd $dim_dir

#create supercell and displacements if not existent
if [ ! -f SPOSCAR ]; then
        echo "Creating displacements"
        phonopy -d --dim="$dim_a $dim_b $dim_c" | grep Spacegroup
        echo ""
fi

#run the ground state structure
if [ ! -d ground_state ] || [ ! -f ground_state/log ]; then

	#display message to change the KPOINTS file
	#I want to do this only once so it's in the GS calculation
	if [ $dim_a -ne 1 ] || [ $dim_b -ne 1 ] || [ $dim_c -ne 1 ]; then
		echo "The supercell dimension changed to $dim_a x $dim_b x $dim_c."
		echo -n "Previous k-mesh dimensions: "; head -4 ../KPOINTS | tail -1
		echo -n "Present  k-mesh dimensions: "; head -4 KPOINTS | tail -1
		echo -n "Do you wish adapt your KPOINTS file? (Y/n) "
		read adapt
		if [ $adapt == "y" ] || [ $adapt == "Y" ] || [ $adapt == "" ]; then
			$EDITOR KPOINTS
			echo -n "Present  k-mesh dimensions: "; head -4 KPOINTS | tail -1
			echo -n "Proceed? (Y/n) "
			read proceed
			if [ ! $proceed == "y" ] && [ ! $proceed == "Y" ] || [ $proceed == "" ]; then
				exit
			fi
		fi
	fi

	mkdir ground_state
	cp INCAR KPOINTS POTCAR ground_state/
	cp SPOSCAR ground_state/POSCAR

	cd ground_state

	#make sure we write the charge and wavecar
	if [ $(grep -i LWAVE INCAR | wc -l) -gt 0 ]; then
		sed -i "s/LWAVE.*=.*$/LWAVE = .TRUE./" INCAR
	else
		echo "LWAVE      = .TRUE." >> INCAR
	fi
	if [ $(grep -i LCHARG INCAR | wc -l) -gt 0 ]; then
		sed -i "s/LCHARG.*=.*$/LCHARG = .TRUE./" INCAR
	else
		echo "LWAVE      = .TRUE." >> INCAR
	fi
	echo "Performing ground state calculation"
	run_calc "ground_state"
	echo ""
	if [ $cluster -eq 1 ]; then
		echo "$(basename $0) will exit. Rerun once ground-state calculation is done to continue"
		exit
	fi

	cd ..
fi

#check ground state calc validity
gs_run=1
echo "Validating ground state calculation"
step=$(tail -3 ground_state/log | head -1 | awk '{print $2}')
conv=$(tail -3 ground_state/log | head -1 | awk '{print $4}')
istep=$(tail -2 ground_state/log | head -1 | awk '{print $1}')
check=$(tail -2 ground_state/log | head -1 | awk '{print $2}')
check2=$(tail -1 ground_state/log | awk '{print $1}')
check3=$(tail -1 ground_state/log | awk '{print $2}')

#first make sure the SCF calculation converged
if [ "$check" != "F=" ] || [ "$check2" != "writing" ] || [ "$check3" != "wavefunctions" ] || [ $istep -ne 1 ] ; then
	gs_run=0
	echo "ground state run did not finish running"
	echo -n "resubmit with parameters cpus: $cpus, walltime: $walltime (Y/n) "
	read resubmit
	if [ $resubmit == "y" ] || [ $resubmit == "Y" ] || [ $resubmit == "" ]; then
		#rerun job with new parameters
		cd ground_state
		run_calc "ground_state"
		cd ..
	fi
else
	#get number of SCF steps from INCAR or otherwise use VASP default
	nemax=$(grep -iE "NELM( )*=" INCAR | awk 'BEGIN{FS="=";found=0}{found=1;print $2}END{if (found == 0)print 60}')

	#check if job ran into max SCF step limit
	#in this case give the user the choice to accept the achived convergence or to rerun
	if [ $step -ge $nemax ]; then
		echo "ground_state ran into NELM limit of $nemax, is converged to $conv"
		echo -n "resubmit with parameters cpus: $cpus, walltime: $walltime (Y/n) "
		read resubmit
		if [ $resubmit == "y" ] || [ $resubmit == "Y" ] || [ $resubmit == "" ]; then
			gs_run=0
			#rerun job with new parameters
			run_calc "ground_state"
		fi
	fi
fi
if [ $gs_run -eq 0 ] && [ $cluster -eq 1 ]; then
	echo "There was a problem with your ground state calculation. Please rerun when fixed."
	exit
fi
echo ""

#at this point inject the keywords to suppress generation of charge and wavecar
if [ $(grep -i LWAVE INCAR | wc -l) -gt 0 ]; then
	sed -i "s/LWAVE.*=.*$/LWAVE = .FALSE./" INCAR
else
	echo "LWAVE      = .FALSE." >> INCAR
fi
if [ $(grep -i LCHARG INCAR | wc -l) -gt 0 ]; then
	sed -i "s/LCHARG.*=.*$/LCHARG = .FALSE./" INCAR
else
	echo "LWAVE      = .FALSE." >> INCAR
fi

#run displacements if not existent
did_one=0
max_displ=$(ls -l POSCAR-* | tail -1 | awk '{print $8}' | awk 'BEGIN{FS="-"}{print $2}')
for poscar in $(ls POSCAR-*); do
	#get the directory number
	number=$(echo $poscar | awk 'BEGIN{FS="-"}{print $2}')
	
	#create directory and copy files
	directoryname=$(echo $number | awk '{printf("displ_%03d", $1)}')
	if [ ! -d $directoryname ]; then
		echo $number $max_displ | awk '{printf("Running displacement %03d of %03d\n", $1, $2)}'

		mkdir $directoryname
		cp INCAR KPOINTS POTCAR $directoryname/
		ln -s ../ground_state/WAVECAR $directoryname/WAVECAR
		cp $poscar $directoryname/POSCAR
		
		cd $directoryname
		run_calc $directoryname
		cd ..
		did_one=1
	fi
done
#if on a cluster exit here to let them run
if [ $did_one -ne 0 ] && [ $cluster -eq 1 ]; then
	echo "$(basename $0) will exit. Rerun when calculations are done to continue"
	exit
fi
if [ $did_one -eq 1 ]; then
	echo ""
fi


#check if all displacements have finished running
echo "Validating displacement runs"
all_good=1
for i in $(ls -d displ_*); do

	step=$(tail -2 $i/log | head -1 | awk '{print $2}')
        conv=$(tail -2 $i/log | head -1 | awk '{print $4}')
        istep=$(tail -1 $i/log | awk '{print $1}')
	check=$(tail -1 $i/log | awk '{print $2}')

	#first make sure the SCF calculation converged
	if [ "$check" != "F=" ] || [ $istep -ne 1 ] ; then
		all_good=0
		echo "$i did not finish running"
		echo -n "resubmit with parameters cpus: $cpus, walltime: $walltime (Y/n) "
		read resubmit
		if [ $resubmit == "y" ] || [ $resubmit == "Y" ] || [ $resubmit == "" ]; then
			#rerun job with new parameters
			cd $i
			run_calc $i
			cd ..
		fi
		continue
	fi

	#get number of SCF steps from INCAR or otherwise use VASP default
	nemax=$(grep -iE "NELM( )*=" $i/INCAR | awk 'BEGIN{FS="=";found=0}{found=1;print $2}END{if (found == 0)print 60}' | awk 'BEGIN{FS="#"}{print $1}')
	
	#check if job ran into max SCF step limit
	#in this case give the user the choice to accept the achived convergence or to rerun
	if [ $step -ge $nemax ]; then
		echo "$i ran into NELM limit of $nemax, is converged to $conv"
		echo -n "resubmit with parameters cpus: $cpus, walltime: $walltime (Y/n) "
		read resubmit
		if [ $resubmit == "y" ] || [ $resubmit == "Y" ] || [ $resubmit == "" ]; then
			all_good=0
			#rerun job with new parameters
			cd $i
			run_calc $i
			cd ..
		fi
	fi

done
if [ ! $all_good -eq 1 ] && [ $cluster -eq 1 ]; then
	echo "There was a problem with some of the displacements. Please rerun when corrected"
	exit
fi
echo ""


#see if force_sets has been created
if [ ! -f FORCE_SETS ]; then
	echo -e "Creating force sets\n"
	phonopy -f displ_*/vasprun.xml &> /dev/null
fi


#create animation if it does not exist for this q-point yet
anime_file_name=$(echo $q_a $q_b $q_c | awk '{printf("anime_%.2f_%.2f_%.2f.ascii", $1, $2, $3)}')
if [ ! -f $anime_file_name ]; then
	if [ $q_a == -1 ] || [ $q_b == -1 ] || [ $q_c == -1 ]; then
		echo "Please set q vector properly to continue"
		exit
	fi
	
	#############################################################
	#TODO sanity check if q point is ok for given dimension
	#############################################################

	echo -e "Creating animation as file $anime_file_name\n"

	cat > v_sim.conf << EOF
DIM = $dim_a $dim_b $dim_c
ANIME_TYPE = V_SIM
ANIME = $q_a $q_b $q_c
EOF
	phonopy v_sim.conf > /dev/null
	mv anime.ascii $anime_file_name
	rm v_sim.conf
fi


#see if we are supposed to modulate
if [ ! $mode -eq -1 ]; then
	
	if [ $q_a == -1 ] || [ $q_b == -1 ] || [ $q_c == -1 ]; then
		echo "Please set q vector properly to continue"
		exit
	fi
	
	mode_dir=$(echo $q_a $q_b $q_c $mode | awk '{printf("mode_%.2f_%.2f_%.2f_%03d", $1, $2, $3, $4)}')
	if [ ! -d $mode_dir ]; then
		mkdir $mode_dir
	fi
	
	#make sure we don't rerun the ground state
	if [ $min == 0.0 ] || [ $min == 0 ]; then
		min=$increment
	fi
	
	#compute eigenvector amplitude
	#
	
	did_one=0
	if [ $min != -1 ] || [ $max != -1 ] || [ $increment != -1 ]; then

		for ampl in $(seq $min $increment $max); do
	
			ampl_dir=$(echo $ampl | awk '{printf("ampl_%.4f", $1)}')
			if [ ! -d $mode_dir/$ampl_dir ]; then
		
				echo $mode $ampl | awk '{printf("Creating modulation for mode %02d @ amplitude %.4f\n", $1, $2)}'
		
				mkdir $mode_dir/$ampl_dir

				#create FORCE_CONSTANTS for the first modulation
				if [ -f FORCE_CONSTANTS ]; then
					echo "DIM = $dim_a $dim_b $dim_c" > modulate.conf
					echo "MODULATION = $q_a $q_b $q_c  $dim_a $dim_b $dim_c, $mode $ampl" >> modulate.conf
				else
					echo "DIM = $dim_a $dim_b $dim_c" > modulate.conf
					echo "MODULATION = $q_a $q_b $q_c $dim_a $dim_b $dim_c, $mode $ampl" >> modulate.conf
					echo "FORCE_CONSTANTS = WRITE" >> modulate.conf
				fi
			
				phonopy modulate.conf > /dev/null
				
				#move the modulated structure to its directory
				mv MPOSCAR $mode_dir/$ampl_dir/POSCAR
			
				#copy the remaining files
				cp INCAR $mode_dir/$ampl_dir/
				cp KPOINTS $mode_dir/$ampl_dir/
				cp POTCAR $mode_dir/$ampl_dir/
		
				cd $mode_dir/$ampl_dir
				run_calc "${mode_dir}_${ampl_dir}"
				cd ../..
				did_one=1
			fi
		done
	
		#delete FORCE_CONSTANTS after last modulation
		if [ -f FORCE_CONSTANTS ]; then
			rm FORCE_CONSTANTS
		fi
	
		if [ -f modulate.conf ]; then
			rm modulate.conf
		fi
	
		#if on a cluster exit here to let them run
		if [ $did_one -ne 0 ] && [ $cluster -eq 1 ]; then
		        echo "$(basename $0) will exit. Rerun when calculations are done to continue"
       		 	exit
		fi
		if [ $did_one -eq 1 ]; then
			echo ""
		fi
	fi

	#check if all modulations have finished running
	echo "Validating modulation steps"
	all_good=1
	for i in $(ls -d $mode_dir/ampl_*); do

		step=$(tail -2 $i/log | head -1 | awk '{print $2}')
		conv=$(tail -2 $i/log | head -1 | awk '{print $4}')
		istep=$(tail -1 $i/log | awk '{print $1}')
		check=$(tail -1 $i/log | awk '{print $2}')

		#first make sure the SCF calculation converged
		if [ "$check" != "F=" ] || [ $istep -ne 1 ] ; then
			echo "$i did not finish running"
			echo -n "resubmit with parameters cpus: $cpus, walltime: $walltime (Y/n) "
			read resubmit
			if [ $resubmit == "y" ] || [ $resubmit == "Y" ] || [ $resubmit == "" ]; then
	                        all_good=0
				#rerun job with new parameters
				cd $i
				name=$(echo $i | awk 'BEGIN{FS="/"}{print $NF}')
				run_calc $name
				cd ../..
			fi
			continue
		fi

		#get number of SCF steps from INCAR or otherwise use VASP default
		nemax=$(grep -iE "NELM( )*=" $i/INCAR | awk 'BEGIN{FS="=";found=0}{found=1;print $2}END{if (found == 0)print 60}')
		
		#check if job ran into max SCF step limit
		#in this case give the user the choice to accept the achived convergence or to rerun
		if [ $step -ge $nemax ]; then
			echo "$i ran into NELM limit of $nemax, is converged to $conv"
			echo -n "resubmit with parameters cpus: $cpus, walltime: $walltime (Y/n) "
			read resubmit
			if [ $resubmit == "y" ] || [ $resubmit == "Y" ] || [ $resubmit == "" ]; then
				all_good=0
				#rerun job with new parameters
				cd $i
				name=$(echo $i | awk 'BEGIN{FS="/"}{print $NF}')
				run_calc $name
				cd ..
			fi
		fi

	done
	if [ ! $all_good -eq 1 ] && [ $cluster -eq 1 ]; then
		echo "There was a problem with some of the modulation amplitudes. Please rerun when corrected"
		exit
	fi
	echo ""
		
	#extract the energy for all modulations of this mode
	echo "Creating modulation energy profile"
	gs_energy=$(grep -i "energy without" ground_state/OUTCAR | tail -1 | awk '{print $5}')
	echo -e "0.0000\t$gs_energy\t0.0000" > temp_results.dat
	for i in $(ls -d $mode_dir/ampl_*); do

		ampl=$(echo $i | awk 'BEGIN{FS="/"}{split($2, tmp, "_"); print tmp[2]}')
		energy=$(grep -i "energy without" $i/OUTCAR | tail -1 | awk '{print $5}')
		delta_energy=$(echo $energy $gs_energy | awk '{print $1 - $2}')
		
		echo -e "$ampl\t$energy\t$delta_energy" >> temp_results.dat
	done
	
	echo "#amplitude energy delta" > $mode_dir.dat
	sort -n temp_results.dat >> $mode_dir.dat
	rm temp_results.dat
fi
