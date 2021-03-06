Module HydrologyNoDrainageMod

  !-----------------------------------------------------------------------
  ! !DESCRIPTION:
  ! Calculate snow and soil temperatures including phase change
  !
  use shr_kind_mod      , only : r8 => shr_kind_r8
  use shr_log_mod       , only : errMsg => shr_log_errMsg
  use decompMod         , only : bounds_type
  use clm_varctl        , only : iulog, use_vichydro
  use clm_varcon        , only : e_ice, denh2o, denice, rpi, spval
  use atm2lndType       , only : atm2lnd_type
  use AerosolType       , only : aerosol_type
  use EnergyFluxType    , only : energyflux_type
  use TemperatureType   , only : temperature_type
  use SoilHydrologyType , only : soilhydrology_type  
  use SoilStateType     , only : soilstate_type
  use WaterfluxType     , only : waterflux_type
  use WaterstateType    , only : waterstate_type
  use LandunitType      , only : lun                
  use ColumnType        , only : col                
  !
  ! !PUBLIC TYPES:
  implicit none
  save
  !
  ! !PUBLIC MEMBER FUNCTIONS:
  public  :: HydrologyNoDrainage ! Calculates soil/snow hydrology without drainage
  !-----------------------------------------------------------------------

contains

  !-----------------------------------------------------------------------
  subroutine HydrologyNoDrainage(bounds, &
       num_nolakec, filter_nolakec, &
       num_hydrologyc, filter_hydrologyc, &
       num_urbanc, filter_urbanc, &
       num_snowc, filter_snowc, &
       num_nosnowc, filter_nosnowc, &
       atm2lnd_vars, soilstate_vars, energyflux_vars, temperature_vars, &
       waterflux_vars, waterstate_vars, &
       soilhydrology_vars, aerosol_vars, &
       soil_water_retention_curve, betrtracer_vars, tracerflux_vars, tracerstate_vars)
    !
    ! !DESCRIPTION:
    ! This is the main subroutine to execute the calculation of soil/snow
    ! hydrology
    ! Calling sequence is:
    !    -> SnowWater:             change of snow mass and snow water onto soil
    !    -> SurfaceRunoff:         surface runoff
    !    -> Infiltration:          infiltration into surface soil layer
    !    -> SoilWater:             soil water movement between layers
    !          -> Tridiagonal      tridiagonal matrix solution
    !    -> Drainage:              subsurface runoff
    !    -> SnowCompaction:        compaction of snow layers
    !    -> CombineSnowLayers:     combine snow layers that are thinner than minimum
    !    -> DivideSnowLayers:      subdivide snow layers that are thicker than maximum
    !
    ! !USES:
    use clm_varcon           , only : denh2o, denice, hfus, grav, tfrz
    use landunit_varcon      , only : istice, istwet, istsoil, istice_mec, istcrop, istdlak 
    use column_varcon        , only : icol_roof, icol_road_imperv, icol_road_perv, icol_sunwall
    use column_varcon        , only : icol_shadewall
    use clm_varctl           , only : use_cn, use_betr
    use clm_varpar           , only : nlevgrnd, nlevsno, nlevsoi, nlevurb
    use clm_time_manager     , only : get_step_size, get_nstep
    use SnowHydrologyMod     , only : SnowCompaction, CombineSnowLayers, DivideSnowLayers
    use SnowHydrologyMod     , only : SnowWater, BuildSnowFilter 
    use SoilHydrologyMod     , only : CLMVICMap, SurfaceRunoff, Infiltration, WaterTable
    use SoilWaterMovementMod , only : SoilWater 
    use SoilWaterRetentionCurveMod, only : soil_water_retention_curve_type
    use TracerParamsMod      , only : pre_diagnose_soilcol_water_flux, diagnose_advect_water_flux, calc_smp_l
    use BetrBGCMod           , only : calc_dew_sub_flux
    use tracerfluxType       , only : tracerflux_type
    use tracerstatetype      , only : tracerstate_type
    use BeTRTracerType       , only : betrtracer_type        
    !
    ! !ARGUMENTS:
    type(bounds_type)        , intent(in)    :: bounds               
    integer                  , intent(in)    :: num_nolakec          ! number of column non-lake points in column filter
    integer                  , intent(in)    :: filter_nolakec(:)    ! column filter for non-lake points
    integer                  , intent(in)    :: num_hydrologyc       ! number of column soil points in column filter
    integer                  , intent(in)    :: filter_hydrologyc(:) ! column filter for soil points
    integer                  , intent(in)    :: num_urbanc           ! number of column urban points in column filter
    integer                  , intent(in)    :: filter_urbanc(:)     ! column filter for urban points
    integer                  , intent(inout) :: num_snowc            ! number of column snow points
    integer                  , intent(inout) :: filter_snowc(:)      ! column filter for snow points
    integer                  , intent(inout) :: num_nosnowc          ! number of column non-snow points
    integer                  , intent(inout) :: filter_nosnowc(:)    ! column filter for non-snow points
    type(atm2lnd_type)       , intent(in)    :: atm2lnd_vars
    type(soilstate_type)     , intent(inout) :: soilstate_vars
    type(energyflux_type)    , intent(in)    :: energyflux_vars
    type(temperature_type)   , intent(inout) :: temperature_vars
    type(waterflux_type)     , intent(inout) :: waterflux_vars
    type(waterstate_type)    , intent(inout) :: waterstate_vars
    type(aerosol_type)       , intent(inout) :: aerosol_vars
    type(soilhydrology_type) , intent(inout) :: soilhydrology_vars
    class(soil_water_retention_curve_type), intent(in) :: soil_water_retention_curve
    type(betrtracer_type)     , intent(in)    :: betrtracer_vars                    ! betr configuration information
    type(tracerflux_type)     , intent(inout) :: tracerflux_vars                    ! tracer flux
    type(tracerstate_type)    , intent(inout) :: tracerstate_vars                   ! tracer state variables data structure    
    !
    ! !LOCAL VARIABLES:
    integer  :: g,l,c,j,fc                    ! indices
    real(r8) :: dtime                         ! land model time step (sec)
    real(r8) :: psi,vwc,fsattmp,psifrz        ! temporary variables for soilpsi calculation
    real(r8) :: watdry                        ! temporary
    real(r8) :: rwat(bounds%begc:bounds%endc) ! soil water wgted by depth to maximum depth of 0.5 m
    real(r8) :: swat(bounds%begc:bounds%endc) ! same as rwat but at saturation
    real(r8) :: rz(bounds%begc:bounds%endc)   ! thickness of soil layers contributing to rwat (m)
    real(r8) :: tsw                           ! volumetric soil water to 0.5 m
    real(r8) :: stsw                          ! volumetric soil water to 0.5 m at saturation
    real(r8) :: fracl                         ! fraction of soil layer contributing to 10cm total soil water
    real(r8) :: s_node                        ! soil wetness (-)
    real(r8) :: icefrac(bounds%begc:bounds%endc,1:nlevsoi)
    !-----------------------------------------------------------------------
    
    associate(                                                          & 
         z                  => col%z                                  , & ! Input:  [real(r8) (:,:) ]  layer depth  (m)                      
         dz                 => col%dz                                 , & ! Input:  [real(r8) (:,:) ]  layer thickness depth (m)             
         zi                 => col%zi                                 , & ! Input:  [real(r8) (:,:) ]  interface depth (m)                   
         snl                => col%snl                                , & ! Input:  [integer  (:)   ]  number of snow layers                    
         ctype              => col%itype                              , & ! Input:  [integer  (:)   ]  column type                              

         t_h2osfc           => temperature_vars%t_h2osfc_col          , & ! Input:  [real(r8) (:)   ]  surface water temperature               
         dTdz_top           => temperature_vars%dTdz_top_col          , & ! Output: [real(r8) (:)   ]  temperature gradient in top layer (col) [K m-1] !
         snot_top           => temperature_vars%snot_top_col          , & ! Output: [real(r8) (:)   ]  snow temperature in top layer (col) [K]  
         t_soisno           => temperature_vars%t_soisno_col          , & ! Output: [real(r8) (:,:) ]  soil temperature (Kelvin)             
         t_grnd             => temperature_vars%t_grnd_col            , & ! Output: [real(r8) (:)   ]  ground temperature (Kelvin)             
         t_grnd_u           => temperature_vars%t_grnd_u_col          , & ! Output: [real(r8) (:)   ]  Urban ground temperature (Kelvin)       
         t_grnd_r           => temperature_vars%t_grnd_r_col          , & ! Output: [real(r8) (:)   ]  Rural ground temperature (Kelvin)       
         t_soi_10cm         => temperature_vars%t_soi10cm_col         , & ! Output: [real(r8) (:)   ]  soil temperature in top 10cm of soil (Kelvin)
         tsoi17             => temperature_vars%t_soi17cm_col         , & ! Output: [real(r8) (:)   ]  soil temperature in top 17cm of soil (Kelvin) 

         snow_depth         => waterstate_vars%snow_depth_col         , & ! Input:  [real(r8) (:)   ]  snow height of snow covered area (m)     
         snowdp             => waterstate_vars%snowdp_col             , & ! Input:  [real(r8) (:)   ]  gridcell averaged snow height (m)       
         frac_sno_eff       => waterstate_vars%frac_sno_eff_col       , & ! Input:  [real(r8) (:)   ]  eff.  snow cover fraction (col) [frc]    
         frac_h2osfc        => waterstate_vars%frac_h2osfc_col        , & ! Input:  [real(r8) (:)   ]  fraction of ground covered by surface water (0 to 1)
         begwb              => waterstate_vars%begwb_col              , & ! Input:  [real(r8) (:)   ]  water mass begining of the time step    
         snw_rds            => waterstate_vars%snw_rds_col            , & ! Output: [real(r8) (:,:) ]  effective snow grain radius (col,lyr) [microns, m^-6] 
         snw_rds_top        => waterstate_vars%snw_rds_top_col        , & ! Output: [real(r8) (:)   ]  effective snow grain size, top layer(col) [microns] 
         sno_liq_top        => waterstate_vars%sno_liq_top_col        , & ! Output: [real(r8) (:)   ]  liquid water fraction in top snow layer (col) [frc] 
         snowice            => waterstate_vars%snowice_col            , & ! Output: [real(r8) (:)   ]  average snow ice lens                   
         snowliq            => waterstate_vars%snowliq_col            , & ! Output: [real(r8) (:)   ]  average snow liquid water               
         snow_persistence   => waterstate_vars%snow_persistence_col   , & ! Output: [real(r8) (:)   ]  counter for length of time snow-covered
         h2osoi_liqice_10cm => waterstate_vars%h2osoi_liqice_10cm_col , & ! Output: [real(r8) (:)   ]  liquid water + ice lens in top 10cm of soil (kg/m2)
         h2osoi_ice         => waterstate_vars%h2osoi_ice_col         , & ! Output: [real(r8) (:,:) ]  ice lens (kg/m2)                      
         h2osoi_liq         => waterstate_vars%h2osoi_liq_col         , & ! Output: [real(r8) (:,:) ]  liquid water (kg/m2)                  
         h2osoi_vol         => waterstate_vars%h2osoi_vol_col         , & ! Output: [real(r8) (:,:) ]  volumetric soil water (0<=h2osoi_vol<=watsat) [m3/m3]
         h2osno_top         => waterstate_vars%h2osno_top_col         , & ! Output: [real(r8) (:)   ]  mass of snow in top layer (col) [kg]    
         wf                 => waterstate_vars%wf_col                 , & ! Output: [real(r8) (:)   ]  soil water as frac. of whc for top 0.05 m 
         wf2                => waterstate_vars%wf2_col                , & ! Output: [real(r8) (:)   ]  soil water as frac. of whc for top 0.17 m 
         h2osoi_liqvol      => waterstate_vars%h2osoi_liqvol_col      , & ! Output: [real(r8) (:,:) ]  volumetric liquid water content
         h2osoi_icevol      => waterstate_vars%h2osoi_icevol_col      , & ! Output: [real(r8) (:,:) ]  volumetric liquid water content         
         air_vol            => waterstate_vars%air_vol_col            , & ! Output: [real(r8) (:,:) ]  volumetric air porosity
         eff_porosity       => soilstate_vars%eff_porosity_col        , & ! Output: [real(r8) (:,:) ]  effective soil porosity

         watsat             => soilstate_vars%watsat_col              , & ! Input:  [real(r8) (:,:) ]  volumetric soil water at saturation (porosity)
         sucsat             => soilstate_vars%sucsat_col              , & ! Input:  [real(r8) (:,:) ]  minimum soil suction (mm)             
         bsw                => soilstate_vars%bsw_col                 , & ! Input:  [real(r8) (:,:) ]  Clapp and Hornberger "b"              
         smp_l              => soilstate_vars%smp_l_col               , & ! Input:  [real(r8) (:,:) ]  soil matrix potential [mm]            
         smpmin             => soilstate_vars%smpmin_col              , & ! Input:  [real(r8) (:)   ]  restriction for min of soil potential (mm)
         soilpsi            => soilstate_vars%soilpsi_col               & ! Output: [real(r8) (:,:) ]  soil water potential in each soil layer (MPa)
         )

      ! Determine step size

      dtime = get_step_size()

      ! Determine initial snow/no-snow filters (will be modified possibly by
      ! routines CombineSnowLayers and DivideSnowLayers below

      call BuildSnowFilter(bounds, num_nolakec, filter_nolakec, &
           num_snowc, filter_snowc, num_nosnowc, filter_nosnowc)

         
      ! Determine the change of snow mass and the snow water onto soil

      call SnowWater(bounds, num_snowc, filter_snowc, num_nosnowc, filter_nosnowc, &
           atm2lnd_vars, waterflux_vars, waterstate_vars, aerosol_vars)

            

      ! mapping soilmoist from CLM to VIC layers for runoff calculations
      if (use_vichydro) then
         call CLMVICMap(bounds, num_hydrologyc, filter_hydrologyc, &
              soilhydrology_vars, waterstate_vars)
      end if

      call SurfaceRunoff(bounds, num_hydrologyc, filter_hydrologyc, num_urbanc, filter_urbanc, &
           soilhydrology_vars, soilstate_vars, waterflux_vars, waterstate_vars)

      call Infiltration(bounds, num_hydrologyc, filter_hydrologyc, num_urbanc, filter_urbanc,&
           energyflux_vars, soilhydrology_vars, soilstate_vars, temperature_vars, &
           waterflux_vars, waterstate_vars)

      if(use_betr)then
        call pre_diagnose_soilcol_water_flux(bounds, num_hydrologyc, filter_hydrologyc, num_urbanc, filter_urbanc, &
          waterstate_vars%h2osoi_liq_col(bounds%begc:bounds%endc, 1:nlevsoi))
      endif
      
      call SoilWater(bounds, num_hydrologyc, filter_hydrologyc, num_urbanc, filter_urbanc, &
            soilhydrology_vars, soilstate_vars, waterflux_vars, waterstate_vars, temperature_vars, &
            soil_water_retention_curve)
            
      if(use_betr)then
        call diagnose_advect_water_flux(bounds, num_hydrologyc, filter_hydrologyc, num_urbanc, filter_urbanc, &
          waterstate_vars%h2osoi_liq_col(bounds%begc:bounds%endc, 1:nlevsoi), &
          soilhydrology_vars%qcharge_col(bounds%begc:bounds%endc), waterflux_vars)                
      endif
        
      call calc_smp_l(bounds, 1, nlevgrnd, num_hydrologyc, filter_hydrologyc, &
          temperature_vars%t_soisno_col(bounds%begc:bounds%endc, 1:nlevgrnd), &
          soilstate_vars, waterstate_vars, soil_water_retention_curve)
             
      if (use_vichydro) then
         ! mapping soilmoist from CLM to VIC layers for runoff calculations
         call CLMVICMap(bounds, num_hydrologyc, filter_hydrologyc, &
              soilhydrology_vars, waterstate_vars)
      end if

      call WaterTable(bounds, num_hydrologyc, filter_hydrologyc, num_urbanc, filter_urbanc, &
           soilhydrology_vars, soilstate_vars, temperature_vars, waterstate_vars, waterflux_vars) 

      if(use_betr)then
        !apply dew and sublimation fluxes, this is a temporary work aroud for tracking water isotope
        !Jinyun Tang, Feb 4, 2015
        call calc_dew_sub_flux(bounds, num_hydrologyc, filter_hydrologyc, waterstate_vars, waterflux_vars, betrtracer_vars, tracerflux_vars, tracerstate_vars)      
      endif           
      ! Natural compaction and metamorphosis.
      call SnowCompaction(bounds, num_snowc, filter_snowc, &
           temperature_vars, waterstate_vars)

      ! Combine thin snow elements
      call CombineSnowLayers(bounds, num_snowc, filter_snowc, &
           aerosol_vars, temperature_vars, waterflux_vars, waterstate_vars)

      ! Divide thick snow elements
      call DivideSnowLayers(bounds, num_snowc, filter_snowc, &
           aerosol_vars, temperature_vars, waterstate_vars, is_lake=.false.)

      ! Set empty snow layers to zero
      do j = -nlevsno+1,0
         do fc = 1, num_snowc
            c = filter_snowc(fc)
            if (j <= snl(c) .and. snl(c) > -nlevsno) then
               h2osoi_ice(c,j) = 0._r8
               h2osoi_liq(c,j) = 0._r8
               t_soisno(c,j)  = 0._r8
               dz(c,j)    = 0._r8
               z(c,j)     = 0._r8
               zi(c,j-1)  = 0._r8
            end if
         end do
      end do
       
      ! Build new snow filter

      call BuildSnowFilter(bounds, num_nolakec, filter_nolakec, &
           num_snowc, filter_snowc, num_nosnowc, filter_nosnowc)

      ! For columns where snow exists, accumulate 'time-covered-by-snow' counters.
      ! Otherwise, re-zero counter, since it is bareland

      do fc = 1, num_snowc
         c = filter_snowc(fc)
         snow_persistence(c) = snow_persistence(c) + dtime
      end do
      do fc = 1, num_nosnowc
         c = filter_nosnowc(fc)
         snow_persistence(c) = 0._r8
      enddo

      ! Vertically average t_soisno and sum of h2osoi_liq and h2osoi_ice
      ! over all snow layers for history output

      do fc = 1, num_nolakec
         c = filter_nolakec(fc)
         snowice(c) = 0._r8
         snowliq(c) = 0._r8
      end do

      do j = -nlevsno+1, 0
         do fc = 1, num_snowc
            c = filter_snowc(fc)
            if (j >= snl(c)+1) then
               snowice(c) = snowice(c) + h2osoi_ice(c,j)
               snowliq(c) = snowliq(c) + h2osoi_liq(c,j)
            end if
         end do
      end do

      ! Calculate column average snow depth
      do c = bounds%begc,bounds%endc
         snowdp(c) = snow_depth(c) * frac_sno_eff(c)
      end do

      ! Determine ground temperature, ending water balance and volumetric soil water
      ! Calculate soil temperature and total water (liq+ice) in top 10cm of soil
      ! Calculate soil temperature and total water (liq+ice) in top 17cm of soil
      do fc = 1, num_nolakec
         c = filter_nolakec(fc)
         l = col%landunit(c)
         if (.not. lun%urbpoi(l)) then
            t_soi_10cm(c) = 0._r8
            tsoi17(c) = 0._r8
            h2osoi_liqice_10cm(c) = 0._r8
         end if
      end do
      do j = 1, nlevsoi
         do fc = 1, num_nolakec
            c = filter_nolakec(fc)
            l = col%landunit(c)
            if (.not. lun%urbpoi(l)) then
               ! soil T at top 17 cm added by F. Li and S. Levis
               if (zi(c,j) <= 0.17_r8) then
                  fracl = 1._r8
                  tsoi17(c) = tsoi17(c) + t_soisno(c,j)*dz(c,j)*fracl
               else
                  if (zi(c,j) > 0.17_r8 .and. zi(c,j-1) < 0.17_r8) then 
                     fracl = (0.17_r8 - zi(c,j-1))/dz(c,j)
                     tsoi17(c) = tsoi17(c) + t_soisno(c,j)*dz(c,j)*fracl
                  end if
               end if

               if (zi(c,j) <= 0.1_r8) then
                  fracl = 1._r8
                  t_soi_10cm(c) = t_soi_10cm(c) + t_soisno(c,j)*dz(c,j)*fracl
                  h2osoi_liqice_10cm(c) = h2osoi_liqice_10cm(c) + &
                       (h2osoi_liq(c,j)+h2osoi_ice(c,j))* &
                       fracl
               else
                  if (zi(c,j) > 0.1_r8 .and. zi(c,j-1) < 0.1_r8) then
                     fracl = (0.1_r8 - zi(c,j-1))/dz(c,j)
                     t_soi_10cm(c) = t_soi_10cm(c) + t_soisno(c,j)*dz(c,j)*fracl
                     h2osoi_liqice_10cm(c) = h2osoi_liqice_10cm(c) + &
                          (h2osoi_liq(c,j)+h2osoi_ice(c,j))* &
                          fracl
                  end if
               end if
            end if
         end do
      end do

      ! TODO - if this block of code is moved out of here - the SoilHydrology 
      ! will NOT effect t_grnd, t_grnd_u or t_grnd_r

      do fc = 1, num_nolakec

         c = filter_nolakec(fc)
         l = col%landunit(c)

         ! t_grnd is weighted average of exposed soil and snow
         if (snl(c) < 0) then
            t_grnd(c) = frac_sno_eff(c) * t_soisno(c,snl(c)+1) &
                 + (1 - frac_sno_eff(c)- frac_h2osfc(c)) * t_soisno(c,1) &
                 + frac_h2osfc(c) * t_h2osfc(c)
         else
            t_grnd(c) = (1 - frac_h2osfc(c)) * t_soisno(c,1) + frac_h2osfc(c) * t_h2osfc(c)
         endif

         if (lun%urbpoi(l)) then
            t_grnd_u(c) = t_soisno(c,snl(c)+1)
         else
            t_soi_10cm(c) = t_soi_10cm(c)/0.1_r8
            tsoi17(c) =  tsoi17(c)/0.17_r8         ! F. Li and S. Levis
         end if
         if (lun%itype(l)==istsoil .or. lun%itype(l)==istcrop) then
            t_grnd_r(c) = t_soisno(c,snl(c)+1)
         end if

      end do

      do j = 1, nlevgrnd
         do fc = 1, num_nolakec
            c = filter_nolakec(fc)
            if ((ctype(c) == icol_sunwall .or. ctype(c) == icol_shadewall &
                 .or. ctype(c) == icol_roof) .and. j > nlevurb) then
            else
               h2osoi_vol(c,j) = h2osoi_liq(c,j)/(dz(c,j)*denh2o) + h2osoi_ice(c,j)/(dz(c,j)*denice)
               h2osoi_liqvol(c,j) = h2osoi_liq(c,j)/(dz(c,j)*denh2o)
               h2osoi_icevol(c,j) = h2osoi_ice(c,j)/(dz(c,j)*denice)
               h2osoi_vol(c,j)    = h2osoi_liqvol(c,j) + h2osoi_icevol(c,j)       
               air_vol(c,j)       = max(1.e-4_r8,watsat(c,j) - h2osoi_vol(c,j))
               eff_porosity(c,j)  = max(0.01_r8,watsat(c,j) - h2osoi_ice(c,j)/(dz(c,j)*denice))
               
            end if
         end do
      end do

      if (use_cn) then
         ! Update soilpsi.
         ! ZMS: Note this could be merged with the following loop updating smp_l in the future.
         do j = 1, nlevgrnd
            do fc = 1, num_hydrologyc
               c = filter_hydrologyc(fc)

               if (h2osoi_liq(c,j) > 0._r8) then

                  vwc = h2osoi_liq(c,j)/(dz(c,j)*denh2o)

                  ! the following limit set to catch very small values of 
                  ! fractional saturation that can crash the calculation of psi

                  ! use the same contants used in the supercool so that psi for frozen soils is consistent
                  fsattmp = max(vwc/watsat(c,j), 0.001_r8)
                  psi = sucsat(c,j) * (-9.8e-6_r8) * (fsattmp)**(-bsw(c,j))  ! Mpa
                  soilpsi(c,j) = min(max(psi,-15.0_r8),0._r8)

               else 
                  soilpsi(c,j) = -15.0_r8
               end if
            end do
         end do
      end if

      ! Update smp_l for history and for ch4Mod.
      ! ZMS: Note, this form, which seems to be the same as used in SoilWater, DOES NOT distinguish between
      ! ice and water volume, in contrast to the soilpsi calculation above. It won't be used in ch4Mod if
      ! t_soisno <= tfrz, though.
      !do j = 1, nlevgrnd
      !   do fc = 1, num_hydrologyc
      !      c = filter_hydrologyc(fc)

      !      s_node = max(h2osoi_vol(c,j)/watsat(c,j), 0.01_r8)
      !      s_node = min(1.0_r8, s_node)

      !      smp_l(c,j) = -sucsat(c,j)*s_node**(-bsw(c,j))
      !      smp_l(c,j) = max(smpmin(c), smp_l(c,j))
      !   end do
      !end do

      if (use_cn) then
         ! Available soil water up to a depth of 0.05 m.
         ! Potentially available soil water (=whc) up to a depth of 0.05 m.
         ! Water content as fraction of whc up to a depth of 0.05 m.

         do fc = 1, num_hydrologyc
            c = filter_hydrologyc(fc)
            rwat(c) = 0._r8
            swat(c) = 0._r8
            rz(c)   = 0._r8
         end do

         do j = 1, nlevgrnd
            do fc = 1, num_hydrologyc
               c = filter_hydrologyc(fc)
               !if (z(c,j)+0.5_r8*dz(c,j) <= 0.5_r8) then
               if (z(c,j)+0.5_r8*dz(c,j) <= 0.05_r8) then
                  watdry = watsat(c,j) * (316230._r8/sucsat(c,j)) ** (-1._r8/bsw(c,j))
                  rwat(c) = rwat(c) + (h2osoi_vol(c,j)-watdry) * dz(c,j)
                  swat(c) = swat(c) + (watsat(c,j)    -watdry) * dz(c,j)
                  rz(c) = rz(c) + dz(c,j)
               end if
            end do
         end do

         do fc = 1, num_hydrologyc
            c = filter_hydrologyc(fc)
            if (rz(c) /= 0._r8) then
               tsw  = rwat(c)/rz(c)
               stsw = swat(c)/rz(c)
            else
               watdry = watsat(c,1) * (316230._r8/sucsat(c,1)) ** (-1._r8/bsw(c,1))
               tsw = h2osoi_vol(c,1) - watdry
               stsw = watsat(c,1) - watdry
            end if
            wf(c) = tsw/stsw
         end do

         do j = 1, nlevgrnd
            do fc = 1, num_hydrologyc
               c = filter_hydrologyc(fc)
               if (z(c,j)+0.5_r8*dz(c,j) <= 0.17_r8) then
                  watdry = watsat(c,j) * (316230._r8/sucsat(c,j)) ** (-1._r8/bsw(c,j))
                  rwat(c) = rwat(c) + (h2osoi_vol(c,j)-watdry) * dz(c,j)
                  swat(c) = swat(c) + (watsat(c,j)    -watdry) * dz(c,j)
                  rz(c) = rz(c) + dz(c,j)
               end if
            end do
         end do

         do fc = 1, num_hydrologyc
            c = filter_hydrologyc(fc)
            if (rz(c) /= 0._r8) then
               tsw  = rwat(c)/rz(c)
               stsw = swat(c)/rz(c)
            else
               watdry = watsat(c,1) * (316230._r8/sucsat(c,1)) ** (-1._r8/bsw(c,1))
               tsw = h2osoi_vol(c,1) - watdry
               stsw = watsat(c,1) - watdry
            end if
            wf2(c) = tsw/stsw
         end do
      end if

      ! top-layer diagnostics
      do fc = 1, num_snowc
         c = filter_snowc(fc)
         h2osno_top(c)  = h2osoi_ice(c,snl(c)+1) + h2osoi_liq(c,snl(c)+1)
      enddo

      ! Zero variables in columns without snow
      do fc = 1, num_nosnowc
         c = filter_nosnowc(fc)
            
         h2osno_top(c)      = 0._r8
         snw_rds(c,:)       = 0._r8

         ! top-layer diagnostics (spval is not averaged when computing history fields)
         snot_top(c)        = spval
         dTdz_top(c)        = spval
         snw_rds_top(c)     = spval
         sno_liq_top(c)     = spval
      end do

    end associate

  end subroutine HydrologyNoDrainage

end Module HydrologyNoDrainageMod
