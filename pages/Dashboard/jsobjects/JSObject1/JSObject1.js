export default {
	async checkLogin () {
		if (!appsmith.store.token) {
  		showAlert('You must be logged in', 'error');
  		navigateTo('Login');
		}
	}
}