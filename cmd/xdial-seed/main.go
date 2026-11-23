// Command xdial-seed keeps company presets single-sourced across platforms.
//
//	xdial-seed legacy-document --authority DIR [--write FILE | --check FILE]
//	xdial-seed check --authority DIR --platform PLATFORM --bundle APP [--profile-name NAME]
//	xdial-seed effective --report FILE [--name-prefix PREFIX]
//
// DIR is the private packaging repository's preset directory: Seed.json (the
// authority, mobile seed format) and RuleSets/ (offline rule files with
// manifest.json). check exits non-zero and lists every difference in routing
// meaning between the package and the authority, except capability limits the
// platform declares below. effective does the same for the configuration an app
// actually applied (a report from XDial --check-seed-acceptance). Nothing here
// contains company configuration.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/seedcheck"
)

// platform describes where a package carries the preset and what it cannot
// represent. "unsupported" parts are skipped by the comparison and printed, so
// a limitation is always visible, never silent.
type platform struct {
	// plainDocument: the app reads only a plain profile document; every other
	// platform reads only the xdial-mobile-seed envelope (MobileSeed.decode on
	// iPhone and Apple TV; on the Mac its revision drives how later builds update).
	plainDocument bool
	seed          func(bundle string) (string, error)
	rules         func(bundle string) (string, error)
	unsupported   map[string]string
}

func single(directory string) (string, error) {
	matches, _ := filepath.Glob(filepath.Join(directory, "*.json"))
	if len(matches) != 1 {
		return "", fmt.Errorf("%s must contain exactly one preset JSON, found %d", directory, len(matches))
	}
	return matches[0], nil
}

func one(pattern string) (string, error) {
	matches, _ := filepath.Glob(pattern)
	if len(matches) != 1 {
		return "", fmt.Errorf("expected one match for %s, found %d", pattern, len(matches))
	}
	return matches[0], nil
}

var platforms = map[string]platform{
	"ios": {
		seed:  func(b string) (string, error) { return filepath.Join(b, "PrivateConfig", "Seed.json"), nil },
		rules: func(b string) (string, error) { return filepath.Join(b, "PrivateConfig", "RuleSets"), nil },
	},
	// Apple TV carries the preset exactly like iPhone.
	"tvos": {
		seed:  func(b string) (string, error) { return filepath.Join(b, "PrivateConfig", "Seed.json"), nil },
		rules: func(b string) (string, error) { return filepath.Join(b, "PrivateConfig", "RuleSets"), nil },
	},
	"macos-store": {
		seed: func(b string) (string, error) {
			return single(filepath.Join(b, "Contents", "Resources", "SeedProfile"))
		},
		rules: func(b string) (string, error) {
			appex, err := one(filepath.Join(b, "Contents", "PlugIns", "*.appex"))
			return filepath.Join(appex, "Contents", "Resources", "SeedProfile", "RuleSets"), err
		},
	},
	"macos": {
		seed: func(b string) (string, error) {
			return single(filepath.Join(b, "Contents", "Resources", "SeedProfile"))
		},
		rules: func(b string) (string, error) {
			extension, err := one(filepath.Join(b, "Contents", "Library", "SystemExtensions", "*.systemextension"))
			return filepath.Join(extension, "Contents", "Resources", "SeedProfile", "RuleSets"), err
		},
	},
	// The 心动 desktop package built from upstream release tags (v0.9.7)
	// reads only a plain profile document and bundles no rule files.
	"desktop-legacy": {
		plainDocument: true,
		seed: func(b string) (string, error) {
			return single(filepath.Join(b, "Contents", "Resources", "SeedProfile"))
		},
		rules: func(string) (string, error) { return "", nil },
		unsupported: map[string]string{
			"regions":          "this app version cannot select a Scenario by exit region; the user picks it",
			"offline_rules":    "this app version bundles no rule files; China rule sets download on first use",
			"rule_set_history": "this app version replaces the preset's rules on every update, so it needs no history",
			"scenario_history": "this app version replaces the preset's Scenario routing on every update, so it needs no history",
		},
	},
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "legacy-document":
		err = legacyDocument(os.Args[2:])
	case "check":
		err = check(os.Args[2:])
	case "effective":
		err = effective(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: xdial-seed legacy-document|check|effective ... (see source header)")
	os.Exit(2)
}

func authority(directory string) (*seedcheck.Seed, map[string]any, []byte, error) {
	data, err := os.ReadFile(filepath.Join(directory, "Seed.json"))
	if err != nil {
		return nil, nil, nil, err
	}
	seed, err := seedcheck.Load(data)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("authority: %v", err)
	}
	if !seed.Mobile {
		return nil, nil, nil, fmt.Errorf("authority Seed.json must be a mobile seed")
	}
	offline, err := seedcheck.OfflineRules(filepath.Join(directory, "RuleSets"))
	if err != nil {
		return nil, nil, nil, fmt.Errorf("authority rules: %v", err)
	}
	return seed, seedcheck.Fingerprint(seed, offline), data, nil
}

func legacyDocument(args []string) error {
	set := flag.NewFlagSet("legacy-document", flag.ContinueOnError)
	directory := set.String("authority", "", "preset directory")
	write := set.String("write", "", "write the generated document here")
	compare := set.String("check", "", "fail if this file differs from the generated document")
	if err := set.Parse(args); err != nil {
		return err
	}
	_, _, data, err := authority(*directory)
	if err != nil {
		return err
	}
	document, err := seedcheck.LegacyProfileDocument(data)
	if err != nil {
		return err
	}
	switch {
	case *write != "":
		return os.WriteFile(*write, document, 0o644)
	case *compare != "":
		current, err := os.ReadFile(*compare)
		if err != nil {
			return err
		}
		if !bytes.Equal(current, document) {
			return fmt.Errorf("%s is not generated from %s/Seed.json; regenerate it with legacy-document --write", *compare, *directory)
		}
		fmt.Println("legacy document matches the authority")
		return nil
	}
	_, err = os.Stdout.Write(document)
	return err
}

func check(args []string) error {
	set := flag.NewFlagSet("check", flag.ContinueOnError)
	directory := set.String("authority", "", "preset directory")
	name := set.String("platform", "", "ios, tvos, macos, macos-store or desktop-legacy")
	bundle := set.String("bundle", "", "built .app")
	profileName := set.String("profile-name", "", "expected Mac preset file name without .json (keeps the installed Profile identity)")
	if err := set.Parse(args); err != nil {
		return err
	}
	target, ok := platforms[*name]
	if !ok {
		return fmt.Errorf("unknown platform %q", *name)
	}
	_, want, _, err := authority(*directory)
	if err != nil {
		return err
	}
	seedPath, err := target.seed(*bundle)
	if err != nil {
		return err
	}
	if *profileName != "" && strings.TrimSuffix(filepath.Base(seedPath), ".json") != *profileName {
		return fmt.Errorf("preset is %s, expected %s.json", filepath.Base(seedPath), *profileName)
	}
	data, err := os.ReadFile(seedPath)
	if err != nil {
		return err
	}
	seed, err := seedcheck.Load(data)
	if err != nil {
		return fmt.Errorf("packaged preset: %v", err)
	}
	if seed.Mobile == target.plainDocument {
		want := "an xdial-mobile-seed envelope"
		if target.plainDocument {
			want = "a plain profile document"
		}
		return fmt.Errorf("%s reads only %s; the packaged preset is not one", *name, want)
	}
	rulesPath, err := target.rules(*bundle)
	if err != nil {
		return err
	}
	offline := map[string]string{}
	if rulesPath != "" {
		if offline, err = seedcheck.OfflineRules(rulesPath); err != nil {
			return fmt.Errorf("packaged rules: %v", err)
		}
	}
	got := seedcheck.Fingerprint(seed, offline)
	var skipped []string
	for part := range target.unsupported {
		skipped = append(skipped, part)
	}
	sort.Strings(skipped)
	differences := seedcheck.Diff(want, got, skipped)
	for _, part := range skipped {
		fmt.Printf("declared limitation (%s): %s — %s\n", *name, part, target.unsupported[part])
	}
	if len(differences) > 0 {
		for _, d := range differences {
			fmt.Fprintln(os.Stderr, "difference:", d)
		}
		return fmt.Errorf("%s package differs from the authority in %d places", *name, len(differences))
	}
	scenarios, _ := want["scenarios"].([]any)
	regions, _ := got["regions"].(map[string]any)
	fmt.Printf("%s package matches the authority: %d Scenarios, %d regions, %d offline rule files\n",
		*name, len(scenarios), len(regions), len(offline))
	return nil
}

// effective compares the configuration an app applied with what the package's
// preset imports to for the same Profile (both written by XDial
// --check-seed-acceptance, so app-side defaults appear on both sides); check
// proves separately that the package preset equals the authority. Only objects
// the preset declares are compared; the user's own Scenarios are counted. The
// active Scenario is the user's choice and offline rule files are checked on
// the package, so both are skipped. A Profile that joined beside others shows
// its Scenario names with a prefix, which --name-prefix removes.
func effective(args []string) error {
	set := flag.NewFlagSet("effective", flag.ContinueOnError)
	path := set.String("report", "", "report written by XDial --check-seed-acceptance")
	prefix := set.String("name-prefix", "", "Scenario name prefix to remove")
	if err := set.Parse(args); err != nil {
		return err
	}
	data, err := os.ReadFile(*path)
	if err != nil {
		return err
	}
	var report struct {
		Profile               config.Profile    `json:"profile"`
		RegionTargets         map[string]string `json:"regionTargets"`
		Expected              *config.Profile   `json:"expected"`
		ExpectedRegionTargets map[string]string `json:"expectedRegionTargets"`
	}
	if err := json.Unmarshal(data, &report); err != nil || report.Expected == nil {
		return fmt.Errorf("invalid report")
	}
	want := seedcheck.Fingerprint(&seedcheck.Seed{Profile: report.Expected, Regions: report.ExpectedRegionTargets}, nil)
	ids := map[string]bool{}
	for _, line := range report.Expected.Lines {
		ids["line:"+line.ID] = true
	}
	for _, rule := range report.Expected.RuleSets {
		ids["rule:"+rule.ID] = true
	}
	for _, scenario := range report.Expected.Scenarios {
		ids["scenario:"+scenario.ID] = true
	}
	applied := config.Profile{}
	others := 0
	for _, line := range report.Profile.Lines {
		if ids["line:"+line.ID] {
			applied.Lines = append(applied.Lines, line)
		}
	}
	for _, rule := range report.Profile.RuleSets {
		if ids["rule:"+rule.ID] {
			applied.RuleSets = append(applied.RuleSets, rule)
		}
	}
	for _, scenario := range report.Profile.Scenarios {
		if !ids["scenario:"+scenario.ID] {
			others++
			continue
		}
		scenario.Name = strings.TrimPrefix(scenario.Name, *prefix)
		applied.Scenarios = append(applied.Scenarios, scenario)
	}
	got := seedcheck.Fingerprint(&seedcheck.Seed{Profile: &applied, Regions: report.RegionTargets}, nil)
	differences := seedcheck.Diff(want, got, []string{"active_scenario", "offline_rules"})
	if len(differences) > 0 {
		for _, d := range differences {
			fmt.Println("difference:", d)
		}
		return fmt.Errorf("the applied configuration differs from the package preset in %d places", len(differences))
	}
	fmt.Printf("applied configuration routes like the package preset: %d Scenarios, %d regions; %d Scenarios of the user's own kept\n",
		len(applied.Scenarios), len(report.RegionTargets), others)
	return nil
}
