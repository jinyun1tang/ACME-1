module PlantSoilnutrientFluxType

  !DESCRIPTIONS
  !
  ! data structure for above/below ground nutrient coupling.
  ! The vision is beyond nitrogen, which probably extends to P, S and ect.
  ! This is part of BeTRbgc
  ! Created by Jinyun Tang, Jan 11, 2015
  use shr_kind_mod           , only : r8 => shr_kind_r8
  use shr_infnan_mod         , only : nan => shr_infnan_nan, assignment(=)
  use shr_log_mod            , only : errMsg => shr_log_errMsg
  use clm_varcon             , only : spval, ispval
  use decompMod              , only : bounds_type  
  use ColumnType             , only : col                
  use PatchType              , only : pft      
  ! !PUBLIC TYPES:
  implicit none
  save
  private
  !
  type, public :: plantsoilnutrientflux_type
  
    real(r8), pointer :: plant_minn_yield_flx_col             (:)    !column level mineral nitrogen yield from soil bgc calculation
    real(r8), pointer :: plant_minn_yield_flx_patch           (:)    !patch level mineral nitrogen yeild from soil bgc calculation
    real(r8), pointer :: plant_minn_yield_flx_vr_col          (:, :) !
    real(r8), pointer :: plant_minn_demand_flx_col            (:)    !column level mineral nitrogen demand
   contains

     procedure , public  :: Init   
     procedure , public  :: SetValues
     procedure , private :: InitAllocate 
     procedure , private :: InitHistory
     procedure , private :: InitCold    
  end type plantsoilnutrientflux_type

 contains
  !------------------------------------------------------------------------
  subroutine Init(this, bounds, lbj, ubj)

    class(plantsoilnutrientflux_type) :: this
    type(bounds_type), intent(in) :: bounds  

    integer          , intent(in) :: lbj, ubj
    
    call this%InitAllocate (bounds, lbj, ubj)
    call this%InitHistory (bounds)
    call this%InitCold (bounds)

  end subroutine Init

  !------------------------------------------------------------------------
  subroutine InitAllocate(this, bounds, lbj, ubj)
    !
    ! !DESCRIPTION:
    ! Initialize pft nitrogen flux
    !
    ! !ARGUMENTS:
    class (plantsoilnutrientflux_type) :: this
    type(bounds_type) , intent(in) :: bounds  
    integer           , intent(in) :: lbj, ubj
    !
    ! !LOCAL VARIABLES:
    integer           :: begp,endp
    integer           :: begc,endc
    
    !------------------------------------------------------------------------

    begp = bounds%begp; endp = bounds%endp
    begc = bounds%begc; endc = bounds%endc

    allocate(this%plant_minn_yield_flx_patch                   (begp:endp)) ; this%plant_minn_yield_flx_patch                   (:)   = nan
    
    allocate(this%plant_minn_yield_flx_col                     (begc:endc)) ; this%plant_minn_yield_flx_col                     (:)   = nan
    
    allocate(this%plant_minn_yield_flx_vr_col                  (begc:endc, lbj:ubj)) ; this%plant_minn_yield_flx_vr_col         (:,:) = nan
    
    allocate(this%plant_minn_demand_flx_col                    (begc:endc)) ; this%plant_minn_demand_flx_col                    (:)   = nan
  end subroutine InitAllocate    


  !------------------------------------------------------------------------
  subroutine InitHistory(this, bounds)
    !
    ! !DESCRIPTION:
    ! Initialize module data structure
    !
    ! 
    ! !USES:
    use shr_infnan_mod , only : nan => shr_infnan_nan, assignment(=)
    use clm_varpar     , only : nlevsno, nlevgrnd, crop_prog, nlevtrc_soil 
    use histFileMod    , only : hist_addfld1d, hist_addfld2d, hist_addfld_decomp
    !
    ! !ARGUMENTS:
    class(plantsoilnutrientflux_type) :: this
    type(bounds_type), intent(in) :: bounds  
    !
    ! !LOCAL VARIABLES:
    integer        :: k,l
    integer        :: begp, endp
    integer        :: begc, endc
    character(10)  :: active
    character(24)  :: fieldname
    character(100) :: longname
    character(8)   :: vr_suffix
    real(r8), pointer :: data2dptr(:,:), data1dptr(:) ! temp. pointers for slicing larger arrays
    !------------------------------------------------------------------------

    begp = bounds%begp; endp= bounds%endp
    begc = bounds%begc; endc= bounds%endc

    this%plant_minn_yield_flx_patch(begp:endp) = spval
    call hist_addfld1d (fname='PLANT_MINN_YIELD_FLX_PATCH', units='gN/m^2/s', &
         avgflag='A', long_name='plant nitrogen uptake flux from soil', &
         ptr_patch=this%plant_minn_yield_flx_patch, default='inactive')    

    this%plant_minn_yield_flx_col(begc:endc) = spval
    call hist_addfld1d (fname='PLANT_MINN_YIELD_FLX_COL', units='gN/m^2/s', &
         avgflag='A', long_name='plant nitrogen uptake flux from soil', &
         ptr_col=this%plant_minn_yield_flx_col)


    this%plant_minn_yield_flx_vr_col(begc:endc,:) = spval
    call hist_addfld_decomp (fname='PLANT_MINN_YIELD_FLX_vr', units='gN/m^3/s', type2d='levtrc', &
            avgflag='A', long_name='plant nitrogen uptake flux from soil', &
            ptr_col=this%plant_minn_yield_flx_vr_col, default='inactive')         

    this%plant_minn_demand_flx_col(begc:endc) = spval
    call hist_addfld1d (fname='PLANT_MINN_DEMAND_FLX', units='gN/m^2/s',  &
            avgflag='A', long_name='plant nitrogen demand flux', &
            ptr_col=plant_minn_demand_flx_col, default='inactive')         
    
  end subroutine InitHistory

  !-----------------------------------------------------------------------
  subroutine SetValues ( this, &
       num_patch, filter_patch, value_patch, &
       num_column, filter_column, value_column)
    !
    ! !DESCRIPTION:
    ! Set nitrogen flux variables
    !
    ! !ARGUMENTS:
    ! !ARGUMENTS:
    class (plantsoilnutrientflux_type) :: this
    integer , intent(in) :: num_patch
    integer , intent(in) :: filter_patch(:)
    real(r8), intent(in) :: value_patch
    integer , intent(in) :: num_column
    integer , intent(in) :: filter_column(:)
    real(r8), intent(in) :: value_column
    !
    ! !LOCAL VARIABLES:
    integer :: fi,i,j,k,l     ! loop index
    !------------------------------------------------------------------------

    do fi = 1,num_patch
       i=filter_patch(fi)
       this%plant_minn_yield_flx_patch(i) = value_patch
    enddo

    do fi = 1,num_column
       i = filter_column(fi)
       this%plant_minn_yield_flx_col(i)   = value_column
    enddo

  end subroutine SetValues
  !-----------------------------------------------------------------------
  subroutine InitCold(this, bounds)
    !
    ! !DESCRIPTION:
    ! Initializes time varying variables used only in coupled carbon-nitrogen mode (CN):
    !
    ! !USES:
    use clm_varpar      , only : crop_prog
    use landunit_varcon , only : istsoil, istcrop
    use LandunitType   , only : lun   
    !
    ! !ARGUMENTS:
    class(plantsoilnutrientflux_type) :: this 
    type(bounds_type), intent(in) :: bounds  
    !
    ! !LOCAL VARIABLES:
    integer :: p,c,l
    integer :: fp, fc                                    ! filter indices
    integer :: num_special_col                           ! number of good values in special_col filter
    integer :: num_special_patch                         ! number of good values in special_patch filter
    integer :: special_col(bounds%endc-bounds%begc+1)    ! special landunit filter - columns
    integer :: special_patch(bounds%endp-bounds%begp+1)  ! special landunit filter - patches
    !---------------------------------------------------------------------

    ! Set column filters

    num_special_col = 0
    do c = bounds%begc, bounds%endc
       l = col%landunit(c)
       if (lun%ifspecial(l)) then
          num_special_col = num_special_col + 1
          special_col(num_special_col) = c
       end if
    end do

    ! Set patch filters

    num_special_patch = 0
    do p = bounds%begp,bounds%endp
       l = pft%landunit(p)
       if (lun%ifspecial(l)) then
          num_special_patch = num_special_patch + 1
          special_patch(num_special_patch) = p
       end if
    end do

    
    call this%SetValues (&
         num_patch=num_special_patch, filter_patch=special_patch, value_patch=0._r8, &
         num_column=num_special_col, filter_column=special_col, value_column=0._r8)    
  end subroutine InitCold    
end module PlantSoilnutrientFluxType